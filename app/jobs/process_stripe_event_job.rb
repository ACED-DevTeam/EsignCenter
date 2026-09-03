# frozen_string_literal: true

# Turns one stored Stripe event into the account's subscription state.
#
# The event is only a TRIGGER: whatever it carries, this job re-fetches the
# CURRENT subscription from Stripe and applies that. Webhook deliveries arrive
# out of order (a cancellation can land before the update that preceded it),
# and re-fetching makes order stop mattering — the object is the truth. That
# also makes every run idempotent, so a failed row can simply be run again.
#
# The fetch, the decision and the write all happen inside StripeBilling::Linker
# — one row lock taken before Stripe is asked anything — so this job only
# resolves WHICH account an event is about and records the verdict.
class ProcessStripeEventJob
  include Sidekiq::Job

  sidekiq_options queue: :billing, retry: 5

  SUBSCRIPTION_EVENTS = %w[
    customer.subscription.created
    customer.subscription.updated
    customer.subscription.deleted
    customer.subscription.paused
    customer.subscription.resumed
    customer.subscription.trial_will_end
  ].freeze

  INVOICE_EVENTS = %w[
    invoice.paid
    invoice.payment_succeeded
    invoice.payment_failed
    invoice.payment_action_required
  ].freeze

  CHECKOUT_EVENT = 'checkout.session.completed'

  # The subscription events that can announce a subscription that is (or is
  # about to be) live. Everything else — deleted, paused — is news about one
  # winding down and needs no defending against.
  LIVE_SUBSCRIPTION_EVENTS = %w[
    customer.subscription.created customer.subscription.updated customer.subscription.resumed
  ].freeze

  UNKNOWN_CUSTOMER = 'unknown customer'
  DUPLICATE_SUBSCRIPTION = 'duplicate subscription cancelled'
  FOREIGN_SUBSCRIPTION = 'foreign subscription'
  NON_CUSTOMER_ACCOUNT = 'non-customer account'

  sidekiq_retries_exhausted do |msg, error|
    inbox = StripeEventInbox.find_by(id: msg['args'].first)
    event_id = inbox&.stripe_event_id || "inbox #{msg['args'].first}"

    ErrorReport.error(error, stripe_event_id: event_id, event_type: inbox&.event_type)

    OperatorAlert.deliver(
      subject: "Stripe event #{event_id} failed 5 times",
      body: "Processing the Stripe webhook #{event_id} (#{inbox&.event_type}) failed five times and " \
            "has been given up on.\nLast error: #{inbox&.last_error}\n\n" \
            'Fix the cause, then re-run it from the Rails console: ' \
            "ProcessStripeEventJob.new.perform(#{inbox&.id})"
    )
  end

  def perform(inbox_id)
    inbox = StripeEventInbox.find_by(id: inbox_id)

    # A row that already reached a verdict is never re-decided; a `failed` one
    # is, which is what makes a retry (or a hand re-run) work.
    return if inbox.nil? || inbox.terminal?

    inbox.update!(status: StripeEventInbox::PROCESSING, attempts: inbox.attempts + 1)

    dispatch(inbox)
  rescue StandardError => e
    record_failure(inbox, e)

    raise
  end

  private

  def dispatch(inbox)
    case inbox.event_type
    when CHECKOUT_EVENT then handle_checkout(inbox)
    when *SUBSCRIPTION_EVENTS then handle_subscription(inbox)
    when *INVOICE_EVENTS then handle_invoice(inbox)
    else ignore!(inbox, "unhandled event type #{inbox.event_type}")
    end
  end

  # A completed Checkout is the only door that can attach a NEW subscription
  # to an account, so it is also the only place a double purchase can happen:
  # two tabs, two completed sessions, two subscriptions, one account. The
  # second one is cancelled at Stripe on the spot rather than left billing.
  def handle_checkout(inbox)
    session = inbox.event_object

    return ignore!(inbox, "checkout session mode #{session['mode']}") unless session['mode'] == 'subscription'

    subscription_row = checkout_subscription_row(session)

    return unknown!(inbox) if subscription_row.nil?
    return ignore!(inbox, NON_CUSTOMER_ACCOUNT) unless customer_row?(subscription_row)

    inbox.update!(account_id: subscription_row.account_id)

    new_subscription_id = session['subscription']

    return ignore!(inbox, 'checkout session carries no subscription') if new_subscription_id.blank?

    record(inbox, link!(inbox, subscription_row, new_subscription_id))
  end

  def handle_subscription(inbox)
    object = inbox.event_object
    subscription_row = row_for(subscription_id: object['id'], customer_id: object['customer'])

    return unknown!(inbox) if subscription_row.nil?
    return ignore!(inbox, NON_CUSTOMER_ACCOUNT) unless customer_row?(subscription_row)

    inbox.update!(account_id: subscription_row.account_id)

    subscription_id = object['id'].presence || subscription_row.stripe_subscription_id

    return ignore!(inbox, 'event carries no subscription') if subscription_id.blank?

    # A SECOND live subscription on a customer that already has one is a
    # double charge however we hear about it — a repeated Checkout, a
    # subscription created by hand in the dashboard. The Linker decides that
    # under the row lock; news that a stranger subscription ENDED needs no
    # action at all, so those events never ask for a cancellation.
    record(inbox, link!(inbox, subscription_row, subscription_id,
                        cancel_duplicates: inbox.event_type.in?(LIVE_SUBSCRIPTION_EVENTS)))
  end

  def handle_invoice(inbox)
    object = inbox.event_object
    subscription_id = invoice_subscription_id(object)
    subscription_row = row_for(subscription_id:, customer_id: object['customer'])

    return unknown!(inbox) if subscription_row.nil?
    return ignore!(inbox, NON_CUSTOMER_ACCOUNT) unless customer_row?(subscription_row)

    inbox.update!(account_id: subscription_row.account_id)

    subscription_id = subscription_id.presence || subscription_row.stripe_subscription_id

    return ignore!(inbox, 'invoice carries no subscription') if subscription_id.blank?

    # An invoice for a subscription this account does not hold is somebody
    # else's business: it never applies, never moves the dunning clock and
    # never cancels anything. The subscription events own duplicates.
    record(inbox, link!(inbox, subscription_row, subscription_id, cancel_duplicates: false))
  end

  # In this API version an invoice names its subscription under
  # `parent.subscription_details`; older payloads carry a top-level
  # `subscription`. Both shapes are read so a replayed old event still works.
  def invoice_subscription_id(invoice)
    invoice.dig('parent', 'subscription_details', 'subscription').presence || invoice['subscription'].presence
  end

  # The one door to Stripe: the Linker takes the row lock, re-fetches, decides
  # and writes.
  def link!(inbox, subscription_row, subscription_id, cancel_duplicates: true)
    StripeBilling::Linker.link_and_apply!(subscription_row, subscription_id,
                                          event_id: inbox.stripe_event_id,
                                          event_at: inbox.stripe_created_at,
                                          cancel_duplicates:)
  end

  # What the Linker decided, written onto the inbox row. A subscription that
  # is not ours — a stranger's, or one the account does not hold — is a
  # fact about somebody else, and is ignored the same way.
  def record(inbox, outcome)
    case outcome.verdict
    when :duplicate_cancelled
      inbox.update!(status: StripeEventInbox::PROCESSED, processed_at: Time.current,
                    last_error: DUPLICATE_SUBSCRIPTION)
    when :duplicate_ignored, :foreign_ignored then ignore!(inbox, FOREIGN_SUBSCRIPTION)
    else processed!(inbox)
    end
  end

  def checkout_subscription_row(session)
    account = Account.find_by(id: session['client_reference_id'])
    billing_account = account && Plans.billing_account(account)

    if billing_account&.customer?
      # INSERT first, SELECT on conflict: the Checkout return and this job
      # can create the row at the same moment, and account_id is unique.
      AccountSubscription.create_or_find_by!(account_id: billing_account.id) do |row|
        row.access_state = 'cancelled'
        row.status = 'none'
        row.quantity = 1
      end
    else
      row_for(subscription_id: session['subscription'], customer_id: session['customer'])
    end
  end

  def row_for(subscription_id:, customer_id:)
    (subscription_id.present? && AccountSubscription.find_by(stripe_subscription_id: subscription_id)) ||
      (customer_id.present? && AccountSubscription.find_by(stripe_customer_id: customer_id)) ||
      nil
  end

  # Internal and operator accounts never bill (Plans::INTERNAL). A row that
  # somehow carries a Stripe id on such an account is a mistake, not an
  # instruction: nothing is applied and nothing is cancelled for it.
  def customer_row?(subscription_row)
    Plans.billing_account(subscription_row.account).customer?
  end

  # An event for a customer or subscription no account owns is a fact about
  # someone else's Stripe account (a shared test key, a deleted account), not
  # an error: it is recorded, reported once, and never retried.
  def unknown!(inbox)
    ErrorReport.warning("Stripe event #{inbox.stripe_event_id} (#{inbox.event_type}) matched no account",
                        stripe_event_id: inbox.stripe_event_id)

    ignore!(inbox, UNKNOWN_CUSTOMER)
  end

  def ignore!(inbox, reason)
    inbox.update!(status: StripeEventInbox::IGNORED, last_error: reason.truncate(StripeEventInbox::ERROR_LIMIT),
                  processed_at: Time.current)
  end

  def processed!(inbox)
    inbox.update!(status: StripeEventInbox::PROCESSED, processed_at: Time.current, last_error: nil)
  end

  # Written outside any transaction the failure may have poisoned, so the row
  # still says what went wrong after the re-raise rolls everything else back.
  def record_failure(inbox, error)
    return if inbox.nil?

    inbox.update_columns(status: StripeEventInbox::FAILED,
                         last_error: "#{error.class}: #{error.message}".truncate(StripeEventInbox::ERROR_LIMIT),
                         updated_at: Time.current)
  rescue StandardError => e
    ErrorReport.error(e, stripe_event_inbox_id: inbox&.id)
  end
end
