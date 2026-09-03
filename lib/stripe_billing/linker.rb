# frozen_string_literal: true

module StripeBilling
  # The ONE path through which an account's row and a Stripe subscription are
  # ever tied together.
  #
  # Everything about one account's subscription happens inside a single row
  # lock, taken BEFORE Stripe is asked anything: the re-fetch, the decision
  # about which subscription the account really holds, the write, and the
  # dunning clock that follows from it. Fetching first and locking second — the
  # shape this replaces — let two workers each fetch a snapshot and then race
  # for the write, so the OLDER snapshot could land last and hand paid access
  # back to a cancelled account.
  #
  # The lock is held across the Stripe calls on purpose: a job or a request
  # holds its database connection for its whole duration anyway, so the lock
  # changes nothing about pool pressure — it only serialises same-account
  # work, which is the point. What it must not do is wait forever, so every
  # Stripe call is on a short leash (StripeBilling.client) and the lock itself
  # gives up after LOCK_TIMEOUT: a job that hits it fails and retries, a web
  # action turns it into "try again in a minute".
  #
  # The webhook processor, the nightly reconciliation and the Checkout doors
  # all come through here, so "which subscription does this account hold?" is
  # answered in exactly one place (SubscriptionPolicy says what is ours and
  # which of several survives):
  #
  #   * the row holds this same id                 → fetch it and apply it;
  #   * the row holds nothing                      → fetch the newcomer; adopt
  #                                                  it if it is ours, else
  #                                                  leave it alone;
  #   * the row holds a DIFFERENT id               → ask Stripe about the
  #     row's OWN subscription, never the cached columns: still live → the
  #     newcomer is a duplicate (cancelled and refunded, or ignored for an
  #     invoice); over → adopt the newcomer if it is ours.
  module Linker
    RESOURCE_MISSING = 'resource_missing'

    # How long a worker waits for another worker's lock on the same account
    # before giving up. Longer than one bounded Stripe round-trip, shorter
    # than anything a person would wait for a page.
    LOCK_TIMEOUT = '10s'

    # Stripe pages a customer's subscriptions; the app reads every page, but
    # never more than this many — a thousand subscriptions on one customer is
    # not a customer, it is a bug somewhere else.
    LIST_PAGE_SIZE = 100
    LIST_PAGE_LIMIT = 10

    # A duplicate is fetched with its latest invoice and that invoice's
    # payments, because cancelling it is only half the job: whatever it
    # already charged has to go back.
    DUPLICATE_EXPAND = ['items.data.price', 'latest_invoice.payments'].freeze
    REFUND_REASON = 'duplicate'

    Outcome = Struct.new(:verdict, :refund)

    Refund = Struct.new(:id, :amount, :currency) do
      # "$30.00" — the price is in dollars and so is every refund of it.
      def formatted_amount
        dollars = format('%.2f', amount.to_i / 100.0)

        currency.to_s.casecmp('usd').zero? ? "$#{dollars}" : "#{dollars} #{currency.to_s.upcase}"
      end
    end

    LiveSubscriptions = Struct.new(:ours, :foreign)

    # A duplicate that charged the customer and cannot be refunded by the app:
    # the job must fail loudly rather than record a cancellation that quietly
    # kept the money.
    class RefundUnavailable < StandardError; end

    module_function

    # The row always exists before any Stripe object can be linked to it
    # (Checkout creates it), so a row lock is enough to serialise every writer.
    # `SET LOCAL` scopes the wait limit to this transaction alone; a wait past
    # it raises ActiveRecord::LockWaitTimeout.
    def with_account_lock(account_subscription, &)
      account_subscription.transaction do
        AccountSubscription.connection.execute(
          AccountSubscription.sanitize_sql_array(['SET LOCAL lock_timeout = ?', LOCK_TIMEOUT])
        )

        account_subscription.with_lock(&)
      end
    end

    # Returns an Outcome whose verdict is :applied, :adopted,
    # :duplicate_cancelled, :duplicate_ignored or :foreign_ignored.
    #
    # `cancel_duplicates` is false for invoices (an invoice never cancels
    # anything). `allow_adopt` is false for the nightly sweep, which has
    # already repaired the row from Stripe and must never repoint it on the
    # strength of a list.
    def link_and_apply!(account_subscription, subscription_id, event_id: nil, event_at: nil,
                        cancel_duplicates: true, notify: true, allow_adopt: true)
      with_account_lock(account_subscription) do
        existing = account_subscription.stripe_subscription_id

        if existing == subscription_id
          apply_current!(account_subscription, subscription_id, event_at:)
        elsif existing.blank?
          adopt_if_ours!(account_subscription, subscription_id, event_id:, event_at:)
        else
          decide_between(account_subscription, subscription_id,
                         event_id:, event_at:, cancel_duplicates:, notify:, allow_adopt:)
        end
      end
    end

    # Every subscription Stripe still calls live for this customer, split into
    # the ones that are ours (survivor first) and strangers we leave alone.
    def live_subscriptions(customer_id, account_id)
      live = customer_subscriptions(customer_id).select { |subscription| SubscriptionPolicy.live?(subscription) }
      ours, foreign = live.partition { |subscription| SubscriptionPolicy.ours?(subscription, account_id) }

      LiveSubscriptions.new(ours: SubscriptionPolicy.survivor_order(ours), foreign:)
    end

    def live_subscription_ids(customer_id, account_id)
      live_subscriptions(customer_id, account_id).ours.map { |subscription| SubscriptionSync.field(subscription, :id) }
    end

    # Under the caller's account lock: whatever live subscriptions of ours the
    # customer already has get linked — the survivor becomes the account's,
    # every other one goes through the duplicate path. Returns whether any
    # was found (so the caller can refuse to sell another).
    def link_live_subscriptions!(account_subscription, customer_id)
      live = live_subscriptions(customer_id, account_subscription.account_id)

      report_foreign(account_subscription, live.foreign)

      live.ours.each do |subscription|
        link_and_apply!(account_subscription, SubscriptionSync.field(subscription, :id))
      end

      live.ours.any?
    end

    # What the ROW says about the subscription it holds, without asking Stripe.
    # Only ever a first, cheap answer (the billing page's buttons, the
    # Checkout pre-check); every decision that moves money asks Stripe.
    def holds_live_subscription?(account_subscription)
      return false if account_subscription.stripe_subscription_id.blank?
      return true if Plans::PAID_ACCESS_STATES.include?(account_subscription.access_state)

      SubscriptionPolicy.live_status?(account_subscription.stripe_status)
    end

    # --- inside the lock -----------------------------------------------------

    # Every page of the customer's subscriptions, dead ones included: the
    # list is filtered here, never by Stripe's paging, so a page of ten dead
    # subscriptions cannot hide a live one behind `has_more`.
    def customer_subscriptions(customer_id)
      return [] if customer_id.blank?

      found = []
      params = { customer: customer_id, status: 'all', limit: LIST_PAGE_SIZE }

      more = true

      LIST_PAGE_LIMIT.times do
        page = StripeBilling.client.v1.subscriptions.list(params)
        found.concat(Array(page.data))
        more = SubscriptionSync.truthy?(SubscriptionSync.field(page, :has_more)) && page.data.any?

        break unless more

        params = params.merge(starting_after: SubscriptionSync.field(page.data.last, :id))
      end

      # A list we could not finish is not a list: deciding "no live
      # subscription" on it could sell a second one.
      if more
        raise StripeBilling::ListIncomplete,
              "customer #{customer_id} has more than #{LIST_PAGE_SIZE * LIST_PAGE_LIMIT} subscriptions"
      end

      found
    end

    # The row holds nothing yet. A newcomer that is not ours is never written
    # onto the row: paid access is not granted for somebody else's purchase.
    def adopt_if_ours!(account_subscription, subscription_id, event_id:, event_at:)
      stripe_subscription = StripeBilling.subscription_for(subscription_id)

      unless SubscriptionPolicy.ours?(stripe_subscription, account_subscription.account_id)
        return foreign_ignored(account_subscription, subscription_id, event_id:)
      end

      account_subscription.update!(stripe_subscription_id: subscription_id)

      apply_object!(account_subscription, stripe_subscription, event_at:)

      Outcome.new(verdict: :adopted)
    end

    # The row holds ANOTHER subscription. Ask Stripe about that one — never
    # the cached columns, which may be stale in either direction — and write
    # what Stripe says while it is in hand. When both are live and ours, the
    # survivor policy decides (not arrival order): the loser goes through
    # the duplicate path whichever one it is.
    def decide_between(account_subscription, subscription_id, event_id:, event_at:, cancel_duplicates:, notify:,
                       allow_adopt:)
      own = StripeBilling.subscription_for(account_subscription.stripe_subscription_id)

      if SubscriptionPolicy.live?(own)
        SubscriptionSync.apply!(account_subscription, own)

        return Outcome.new(verdict: :duplicate_ignored) unless cancel_duplicates

        settle_between_live!(account_subscription, own, subscription_id, event_id:, event_at:, notify:)
      elsif allow_adopt
        adopt_if_ours!(account_subscription, subscription_id, event_id:, event_at:)
      else
        Outcome.new(verdict: :duplicate_ignored)
      end
    end

    # The row's own subscription is live; the newcomer is fetched and, if it
    # is live too and wins on the survivor policy (our price, earliest
    # created), the row moves to it and the FORMER subscription is the
    # duplicate. Otherwise the newcomer is.
    def settle_between_live!(account_subscription, own, subscription_id, event_id:, event_at:, notify:)
      incoming = StripeBilling.subscription_for(subscription_id, expand: DUPLICATE_EXPAND)

      refuse_foreign!(account_subscription, incoming)

      incoming_wins = SubscriptionPolicy.live?(incoming) &&
                      SubscriptionPolicy.survivor_order([own, incoming]).first.equal?(incoming)

      unless incoming_wins
        return cancel_duplicate!(account_subscription, subscription_id, event_id:, notify:, duplicate: incoming)
      end

      former_id = account_subscription.stripe_subscription_id

      account_subscription.update!(stripe_subscription_id: subscription_id)
      apply_object!(account_subscription, incoming, event_at:)

      cancel_duplicate!(account_subscription, former_id, event_id:, notify:)
    end

    # Never trust the payload that got us here: ask Stripe what is true now
    # and write that. Idempotent, so a replayed or out-of-order event simply
    # writes the same row again.
    def apply_current!(account_subscription, subscription_id, event_at:)
      apply_object!(account_subscription, StripeBilling.subscription_for(subscription_id), event_at:)

      Outcome.new(verdict: :applied)
    end

    def apply_object!(account_subscription, stripe_subscription, event_at:)
      SubscriptionSync.apply!(account_subscription, stripe_subscription)

      stamp_event!(account_subscription, event_at)
    end

    # The newest Stripe event this row has seen; it never moves backwards.
    def stamp_event!(account_subscription, event_at)
      newest = [account_subscription.last_stripe_event_at, event_at].compact.max

      account_subscription.update!(last_stripe_event_at: newest) if newest
    end

    def foreign_ignored(account_subscription, subscription_id, event_id:)
      ErrorReport.warning("Stripe subscription #{subscription_id} on account " \
                          "#{account_subscription.account_id}'s customer is not ours; left alone",
                          account_id: account_subscription.account_id, stripe_event_id: event_id)

      Outcome.new(verdict: :foreign_ignored)
    end

    def report_foreign(account_subscription, foreign)
      foreign.each do |subscription|
        ErrorReport.warning("foreign subscription #{SubscriptionSync.field(subscription, :id)} on customer " \
                            "#{account_subscription.stripe_customer_id} left alone",
                            account_id: account_subscription.account_id)
      end
    end

    # --- the duplicate path --------------------------------------------------

    # A second live subscription of ours on one customer is a double charge
    # however we hear about it. The newcomer is fetched (a stranger's
    # subscription is refused outright, never cancelled), cancelled at
    # Stripe, and whatever it already charged is refunded; the operator is
    # told either way. `notify` is false for the nightly sweep, which sends
    # ONE summary email however many duplicates it found — except when a
    # refund fails, which always reaches a person.
    #
    # Only what WE cancel is ever refunded. A candidate that is already dead
    # when fetched is somebody's history — a stale event for an old,
    # legitimately ended subscription, a bookmarked return URL — unless it
    # carries our own cancellation marker, which means a previous attempt
    # cancelled it and its refund is still owed.
    def cancel_duplicate!(account_subscription, duplicate_id, event_id: nil, notify: true, duplicate: nil)
      duplicate ||= StripeBilling.subscription_for(duplicate_id, expand: DUPLICATE_EXPAND)

      refuse_foreign!(account_subscription, duplicate)

      cancelled = SubscriptionPolicy.dead?(duplicate) ? cancelled_by_us(duplicate) : cancel_at_stripe!(duplicate)

      return stale_ignored(account_subscription, duplicate_id, event_id:) if cancelled.nil?

      refund = refund_duplicate_charge!(cancelled)

      report_duplicate(account_subscription, duplicate_id, refund:, event_id:, notify:)

      Outcome.new(verdict: :duplicate_cancelled, refund:)
    rescue Stripe::StripeError, RefundUnavailable => e
      raise unless cancelled

      report_duplicate(account_subscription, duplicate_id, refund_error: e, event_id:, notify: true)

      raise
    end

    def refuse_foreign!(account_subscription, duplicate)
      return if SubscriptionPolicy.ours?(duplicate, account_subscription.account_id)

      raise ArgumentError, "refusing to cancel #{SubscriptionSync.field(duplicate, :id)}: it is not an " \
                           "EsignCenter subscription (account #{account_subscription.account_id})"
    end

    # Returns the cancelled subscription as Stripe now sees it, stamped with
    # our marker; or nil when it was already gone by someone else's hand
    # (nothing of ours to refund). Only "it is already gone" is swallowed:
    # any other invalid request means the duplicate may still be billing
    # somebody, and the job must retry rather than record a cancellation
    # that never happened.
    def cancel_at_stripe!(duplicate)
      duplicate_id = SubscriptionSync.field(duplicate, :id)

      StripeBilling.client.v1.subscriptions.cancel(
        duplicate_id,
        { expand: DUPLICATE_EXPAND, cancellation_details: { comment: StripeBilling::DUPLICATE_CANCEL_MARKER } }
      )
    rescue Stripe::InvalidRequestError => e
      raise unless already_gone?(e, duplicate_id)

      Rails.logger.info("Duplicate subscription #{duplicate_id} was already gone (#{e.message})")

      nil
    end

    # Stripe explicitly calls it finished (or never heard of it). A missing
    # or blank status is not "gone".
    def already_gone?(error, duplicate_id)
      return true if error.code.to_s == RESOURCE_MISSING

      SubscriptionPolicy.dead?(StripeBilling.subscription_for(duplicate_id, expand: DUPLICATE_EXPAND))
    rescue Stripe::StripeError
      false
    end

    # A dead subscription is ours to refund only if we are the ones who
    # ended it: our marker in its cancellation details says so.
    def cancelled_by_us(dead_subscription)
      comment = SubscriptionSync.field(SubscriptionSync.field(dead_subscription, :cancellation_details), :comment)

      comment.to_s == StripeBilling::DUPLICATE_CANCEL_MARKER ? dead_subscription : nil
    end

    def stale_ignored(account_subscription, duplicate_id, event_id:)
      Rails.logger.info("Subscription #{duplicate_id} on account #{account_subscription.account_id} was already " \
                        'over and not cancelled by us; nothing cancelled, nothing refunded')
      ErrorReport.info("stale subscription #{duplicate_id} ignored (already over, not ours to refund)",
                       account_id: account_subscription.account_id, stripe_event_id: event_id)

      Outcome.new(verdict: :duplicate_ignored)
    end

    # Money back for whatever the duplicate collected. Stripe's own
    # idempotency key means a retried job cannot refund the same invoice
    # twice. A trial duplicate has a $0 invoice and nothing to refund.
    def refund_duplicate_charge!(cancelled)
      invoice = SubscriptionSync.field(cancelled, :latest_invoice)
      amount_paid = SubscriptionSync.field(invoice, :amount_paid).to_i

      return nil unless amount_paid.positive?

      payment_intent = paid_payment_intent(invoice)

      if payment_intent.blank?
        raise RefundUnavailable, "invoice #{SubscriptionSync.field(invoice, :id)} collected #{amount_paid} " \
                                 'but names no payment intent to refund'
      end

      refund = StripeBilling.client.v1.refunds.create(
        { payment_intent:, reason: REFUND_REASON },
        idempotency_key: "refund-duplicate-#{SubscriptionSync.field(invoice, :id)}"
      )

      Refund.new(id: refund.id, amount: refund.amount || amount_paid,
                 currency: SubscriptionSync.field(invoice, :currency))
    end

    # In this API version an invoice's payments live under `payments` (a
    # list, expanded on request); the one that settled it names its
    # PaymentIntent. A bare id when unexpanded, an object when expanded.
    def paid_payment_intent(invoice)
      payments = Array(SubscriptionSync.field(SubscriptionSync.field(invoice, :payments), :data))

      paid = payments.find do |payment|
        SubscriptionSync.field(payment, :status).to_s == 'paid' &&
          SubscriptionSync.field(SubscriptionSync.field(payment, :payment), :type).to_s == 'payment_intent'
      end

      intent = SubscriptionSync.field(SubscriptionSync.field(paid, :payment), :payment_intent)

      intent.is_a?(String) ? intent : SubscriptionSync.field(intent, :id)
    end

    def report_duplicate(account_subscription, duplicate_id, event_id:, notify:, refund: nil, refund_error: nil)
      message = "Cancelled duplicate Stripe subscription #{duplicate_id} for account " \
                "#{account_subscription.account_id}; it already has #{account_subscription.stripe_subscription_id}"

      ErrorReport.warning(message, account_id: account_subscription.account_id, stripe_event_id: event_id,
                                   refund_id: refund&.id, refund_error: refund_error&.message)

      return unless notify

      OperatorAlert.deliver(
        subject: "Duplicate Stripe subscription cancelled for account #{account_subscription.account_id}",
        body: "#{message}.\n\n#{duplicate_money_note(refund, refund_error)}"
      )
    end

    def duplicate_money_note(refund, refund_error)
      if refund_error
        "REFUND FAILED — refund manually in the Stripe dashboard (#{refund_error.class}: " \
          "#{refund_error.message}). The duplicate is cancelled but its charge has NOT been returned."
      elsif refund
        "Its charge of #{refund.formatted_amount} was refunded (#{refund.id})."
      else
        'Nothing was charged twice, but check the customer in Stripe to be sure only one subscription is live.'
      end
    end
  end
end
