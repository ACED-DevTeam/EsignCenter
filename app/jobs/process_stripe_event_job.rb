# frozen_string_literal: true

# Turns one stored Stripe event into the account's subscription state.
#
# The event is only a TRIGGER: whatever it carries, this job re-fetches the
# CURRENT subscription from Stripe and applies that. Webhook deliveries arrive
# out of order (a cancellation can land before the update that preceded it),
# and re-fetching makes order stop mattering — the object is the truth. That
# also makes every run idempotent, so a failed row can simply be run again.
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

  # Events that clear the dunning clock, and the one that starts it.
  PAID_INVOICE_EVENTS = %w[invoice.paid invoice.payment_succeeded].freeze
  FAILED_INVOICE_EVENT = 'invoice.payment_failed'

  # The subscription events that can announce a subscription that is (or is
  # about to be) live. Everything else — deleted, paused — is news about one
  # winding down and needs no defending against.
  LIVE_SUBSCRIPTION_EVENTS = %w[
    customer.subscription.created customer.subscription.updated customer.subscription.resumed
  ].freeze

  UNKNOWN_CUSTOMER = 'unknown customer'
  DUPLICATE_SUBSCRIPTION = 'duplicate subscription cancelled'
  FOREIGN_SUBSCRIPTION = 'event for a subscription this account does not hold'

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

    inbox.update!(account_id: subscription_row.account_id)

    new_subscription_id = session['subscription']

    return ignore!(inbox, 'checkout session carries no subscription') if new_subscription_id.blank?
    return cancel_duplicate!(inbox, subscription_row, new_subscription_id) if duplicate?(subscription_row,
                                                                                         new_subscription_id)

    subscription_row.update!(stripe_subscription_id: new_subscription_id) if
      subscription_row.stripe_subscription_id.blank?

    refresh_and_apply!(inbox, subscription_row, new_subscription_id)

    processed!(inbox)
  end

  def handle_subscription(inbox)
    object = inbox.event_object
    subscription_row = row_for(subscription_id: object['id'], customer_id: object['customer'])

    return unknown!(inbox) if subscription_row.nil?

    inbox.update!(account_id: subscription_row.account_id)

    subscription_id = object['id'].presence || subscription_row.stripe_subscription_id

    return ignore!(inbox, 'event carries no subscription') if subscription_id.blank?

    if duplicate?(subscription_row, subscription_id)
      # A SECOND live subscription on a customer that already has one is a
      # double charge however we hear about it — a repeated Checkout, a
      # subscription created by hand in the dashboard. Whoever tells us, the
      # new one goes away and the account keeps the one it already had. News
      # that the stranger ENDED needs no action at all: acting on it would
      # only ask Stripe to cancel something already gone.
      return ignore!(inbox, FOREIGN_SUBSCRIPTION) unless inbox.event_type.in?(LIVE_SUBSCRIPTION_EVENTS)

      return cancel_duplicate!(inbox, subscription_row, subscription_id)
    end

    refresh_and_apply!(inbox, subscription_row, subscription_id)

    processed!(inbox)
  end

  def handle_invoice(inbox)
    object = inbox.event_object
    subscription_id = invoice_subscription_id(object)
    subscription_row = row_for(subscription_id:, customer_id: object['customer'])

    return unknown!(inbox) if subscription_row.nil?

    inbox.update!(account_id: subscription_row.account_id)

    subscription_id = subscription_id.presence || subscription_row.stripe_subscription_id

    return ignore!(inbox, 'invoice carries no subscription') if subscription_id.blank?

    refresh_and_apply!(inbox, subscription_row, subscription_id)
    record_dunning_clock(inbox, subscription_row)

    processed!(inbox)
  end

  # In this API version an invoice names its subscription under
  # `parent.subscription_details`; older payloads carry a top-level
  # `subscription`. Both shapes are read so a replayed old event still works.
  def invoice_subscription_id(invoice)
    invoice.dig('parent', 'subscription_details', 'subscription').presence || invoice['subscription'].presence
  end

  # The failed payment starts the clock Session 7's dunning reads; any
  # successful payment stops it.
  def record_dunning_clock(inbox, subscription_row)
    if inbox.event_type == FAILED_INVOICE_EVENT
      return unless subscription_row.access_state == 'past_due' && subscription_row.past_due_since.nil?

      subscription_row.update!(past_due_since: Time.current)
    elsif inbox.event_type.in?(PAID_INVOICE_EVENTS) && subscription_row.past_due_since.present?
      subscription_row.update!(past_due_since: nil)
    end
  end

  # The whole point of the inbox: never trust the delivered payload, ask
  # Stripe what is true now. An event older than one already applied still
  # re-fetches and applies — the answer is simply the same, and the stamp of
  # the newest event seen never moves backwards.
  def refresh_and_apply!(inbox, subscription_row, subscription_id)
    stripe_subscription = StripeBilling.subscription_for(subscription_id)

    subscription_row.with_lock do
      StripeBilling::SubscriptionSync.apply!(subscription_row, stripe_subscription)

      newest = [subscription_row.last_stripe_event_at, inbox.stripe_created_at].compact.max

      subscription_row.update!(last_stripe_event_at: newest) if newest
    end
  end

  def checkout_subscription_row(session)
    account = Account.find_by(id: session['client_reference_id'])
    billing_account = account && Plans.billing_account(account)

    if billing_account&.customer?
      AccountSubscription.find_or_create_by!(account_id: billing_account.id) do |row|
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

  # "The account already bought this once": a live paid subscription under a
  # different id than the one this Checkout produced.
  def duplicate?(subscription_row, new_subscription_id)
    existing = subscription_row.stripe_subscription_id

    existing.present? && existing != new_subscription_id &&
      Plans::PAID_ACCESS_STATES.include?(subscription_row.access_state)
  end

  def cancel_duplicate!(inbox, subscription_row, new_subscription_id)
    begin
      StripeBilling.client.v1.subscriptions.cancel(new_subscription_id)
    rescue Stripe::InvalidRequestError => e
      # Already cancelled, or never existed: a repeated delivery of the same
      # event must land in the same place rather than fail forever.
      Rails.logger.info("Duplicate subscription #{new_subscription_id} was already gone (#{e.message})")
    end

    message = "Cancelled duplicate Stripe subscription #{new_subscription_id} for account " \
              "#{subscription_row.account_id}; it already has #{subscription_row.stripe_subscription_id}"

    ErrorReport.warning(message, account_id: subscription_row.account_id,
                                 stripe_event_id: inbox.stripe_event_id)

    OperatorAlert.deliver(
      subject: "Duplicate Stripe subscription cancelled for account #{subscription_row.account_id}",
      body: "#{message}.\n\nNothing was charged twice, but check the customer in Stripe " \
            'to be sure only one subscription is live.'
    )

    inbox.update!(status: StripeEventInbox::PROCESSED, processed_at: Time.current,
                  last_error: DUPLICATE_SUBSCRIPTION)
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
