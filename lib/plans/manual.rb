# frozen_string_literal: true

module Plans
  # Putting an account on the paid plan BY HAND, and taking it off again.
  #
  # Two doors reach this: `rake plans:grant` / `rake plans:revoke`, and the
  # operator console's Comp panel. They were the same twenty lines copied
  # twice until Session 8 — which is exactly the shape that lets one of them
  # keep a guard the other has lost — so the decision, the refusals and the
  # writes live here and the two doors only differ in how they report.
  #
  # A grant is a COMP: paid access this app is giving away rather than selling.
  # The console always attaches an expiry date to one (`comp_expires_at`,
  # swept hourly by CompExpiryJob); the rake may still grant without one, for
  # the internal fixtures and pilots that predate the column.
  module Manual
    # Something about the account or its subscription says this change must
    # not be made. Carries the sentence a person reads: the rake aborts with
    # it, the console renders it on the page.
    class Refused < StandardError; end

    # How long a started Checkout is treated as still in flight.
    #
    # A Checkout that has begun leaves a row holding the Stripe CUSTOMER and
    # nothing else — `status` 'none', no subscription id, no Stripe status
    # (BillingSettingsController#ensure_subscription_row!). Granting over that
    # row is the review carry-over C9: the grant lands, the customer finishes
    # paying a minute later, and the webhook writes Stripe's answer straight
    # over it — so the operator's comp silently disappears and nobody is told.
    #
    # Bounded rather than permanent, because a Checkout nobody finished must
    # not lock the account out of comps for ever. Stripe's own Checkout
    # sessions expire after 24 hours; past that the session can no longer
    # complete, so there is no webhook left to overwrite anything.
    CHECKOUT_IN_FLIGHT_WINDOW = 24.hours

    module_function

    # Billing belongs to the BILLING account: a testing or linked child is
    # paid for by its parent, and writing a subscription row on the child
    # would put a row where nothing reads it.
    def billing_account!(account)
      billing = Plans.billing_account(account)

      unless billing.customer?
        raise Refused, "Account #{billing.id} is #{billing.account_kind}: it is always on the " \
                       "#{Plans::INTERNAL} plan."
      end

      billing
    end

    # Paid, by hand. `seats` is the quantity the plan pretends to have bought;
    # `comp_expires_at` is when it ends (nil only from the rake).
    def grant!(account, seats: 1, comp_expires_at: nil)
      raise Refused, 'Seats must be at least 1.' if seats.to_i < 1

      billing = billing_account!(account)

      with_row_lock(billing) do |subscription|
        assert_ours!(subscription, 'grant')

        # A dead Stripe subscription's ids are cleared so the row cannot be
        # mistaken for Stripe-backed again; the customer id and the one-trial
        # stamp are the account's history and stay.
        #
        # `ended_at` is cleared with them, exactly as StripeBilling::SubscriptionSync
        # clears it when a row comes back to life: it marks where a FREE month
        # started (D43, prospective counters), and a paid account has no such
        # mark. Leaving a stale one behind would shorten the free month of the
        # next revoke to a date that belonged to the previous one.
        subscription.update!(access_state: 'active', quantity: seats.to_i, status: 'manual',
                             cancel_at_period_end: false, stripe_subscription_id: nil,
                             stripe_status: nil, ended_at: nil, comp_expires_at:)

        subscription
      end
    end

    # Back to free. The row STAYS (D43): a downgrade never deletes the money
    # history. Returns nil when there was no row to revoke.
    def revoke!(account)
      billing = billing_account!(account)

      return nil if billing.account_subscription.nil?

      with_row_lock(billing) do |subscription|
        assert_ours!(subscription, 'revoke')

        apply_revoke!(billing, subscription)
      end
    end

    # The comp sweep's whole write, and every one of its decisions is made
    # INSIDE the row lock (review 1, Codex).
    #
    # CompExpiryJob chose this row from a query that ran minutes ago, and two
    # things can have happened since: the operator can have extended the comp
    # (a later `comp_expires_at`), or a webhook can have replaced the manual
    # row with a live Stripe subscription. Revoking on the strength of the old
    # read would take away a comp somebody had just extended, or cancel access
    # a customer is being charged for. So the date and the `manual` status are
    # re-read here, under the lock, and a row that no longer answers "yes" to
    # both is left exactly as it is (nil).
    def revoke_expired_comp!(account, now: Time.current)
      billing = billing_account!(account)

      return nil if billing.account_subscription.nil?

      with_row_lock(billing) do |subscription|
        next nil unless subscription.status == 'manual'
        next nil if subscription.comp_expires_at.blank? || subscription.comp_expires_at > now

        assert_ours!(subscription, 'revoke')

        apply_revoke!(billing, subscription)
      end
    end

    # The write both revoke doors share. Called with the row already locked.
    def apply_revoke!(billing, subscription)
      # A manual row's stale Stripe ids go with the grant they belonged to, so
      # the next grant is not mistaken for writing over a live subscription.
      stale_ids = subscription.status == 'manual' ? { stripe_subscription_id: nil, stripe_status: nil } : {}

      # Read BEFORE the write. A hand-revoke ends paid access exactly as a
      # Stripe cancellation does, so it has to leave the same trail (D43,
      # prospective counters): the moment the paid plan stopped, and a
      # snapshot of the send counter taken there. Without them the account
      # would keep counting the documents it sent while it was paying and read
      # "12 of 5" on the free plan.
      #
      # A row that was never paid is never stamped (same refusal as
      # StripeBilling::SubscriptionSync#ended_at_for): a Checkout that never
      # completed must not be able to restart a free month.
      was_paid = Plans.paid_subscription?(billing)
      ended = was_paid ? { ended_at: subscription.ended_at || Time.current } : {}

      subscription.update!(access_state: 'cancelled', status: 'canceled', cancel_at_period_end: false,
                           comp_expires_at: nil, **stale_ids, **ended)

      Quotas.record_downgrade!(billing) if was_paid

      # THE SEATS. A paid plan ending by hand ends it exactly as Stripe ending
      # it does, and that is not only the counters: an account that filled
      # three comp seats and is now on a one-seat free plan has to keep one
      # administrator writable and park the rest read-only, and hand back the
      # invitations that were holding seats for people who never arrived
      # (D43). None of that used to happen — a revoked comp left every surplus
      # member writing indefinitely, because the hourly seat sweep only ever
      # looks at Stripe-backed rows.
      #
      # So this calls the SAME entry point StripeBilling::SubscriptionSync
      # calls after it applies a subscription — not a copy of its steps — and
      # a manual downgrade and a Stripe one are the same downgrade from here
      # on. It never raises (BillingLifecycle guards every step of it).
      BillingLifecycle.after_apply!(subscription)

      subscription
    end

    # The row, created if this account has never had one, then LOCKED — with
    # the same discipline every Stripe writer uses
    # (StripeBilling::Linker.with_account_lock: the subscription row's own
    # lock, under a bounded lock_timeout).
    #
    # This is what makes a manual grant or revoke serialise with the webhook
    # processor, the Checkout return and the nightly reconciliation instead of
    # racing them. Before it, `assert_ours!` read an object loaded outside any
    # lock: a webhook could attach a live Stripe subscription between the
    # check and the write, and the revoke would then clear the brand-new
    # `stripe_subscription_id` as though it were a stale one — leaving a
    # subscription that goes on charging the customer with nothing in this
    # app watching it. The row is re-read inside the lock (`with_lock`
    # reloads), so every decision below is made on what is actually there.
    def with_row_lock(billing)
      # The create is INSIDE the transaction the lock opens, so a refusal takes
      # it back with everything else: a grant refused for a live Stripe
      # subscription must not leave a half-built row behind on an account that
      # never had one.
      ApplicationRecord.transaction do
        row = AccountSubscription.create_or_find_by!(account_id: billing.id) do |fresh|
          fresh.access_state = 'cancelled'
          fresh.status = 'none'
          fresh.quantity = 1
        end

        StripeBilling::Linker.with_account_lock(row) { yield row }
      end
    end

    # Both refusals, in one question: is this row the operator's to edit at
    # all? Named for what it answers rather than for either half, because
    # every door has to ask both — a row Stripe is driving and a row Stripe is
    # about to drive are equally not ours.
    def assert_ours!(subscription, action)
      refuse_stripe_backed!(subscription, action)
      refuse_checkout_in_flight!(subscription, action)

      true
    end

    # A row Stripe is driving is not the operator's to edit: writing 'manual'
    # over it would take it out of the nightly sweep while Stripe kept
    # charging the card, and setting it back to cancelled would be undone by
    # the next webhook. Stripe cancels Stripe subscriptions.
    #
    # "Stripe is driving it" means exactly one thing: the raw Stripe status
    # last seen is live. A row the operator granted (`manual`) is always the
    # operator's, whatever stale ids it still carries, and a paid access_state
    # on its own proves nothing about Stripe.
    def refuse_stripe_backed!(subscription, action)
      return if subscription.nil? || subscription.status == 'manual'
      return unless StripeBilling::SubscriptionPolicy.live_status?(subscription.stripe_status)

      raise Refused, "Account #{subscription.account_id} has a live Stripe subscription " \
                     "(#{subscription.stripe_subscription_id}, #{subscription.stripe_status}): " \
                     "do not #{action} it by hand — cancel it at Stripe (Customer Portal or dashboard) " \
                     'and the webhook downgrades the account.'
    end

    def refuse_checkout_in_flight!(subscription, action)
      return unless checkout_in_flight?(subscription)

      raise Refused, "Account #{subscription.account_id} has a Stripe checkout in progress: do not #{action} " \
                     'the plan by hand until it finishes, because the webhook that finishes it would write ' \
                     'straight over what you set. Wait for the purchase to land (or for the session to ' \
                     'expire) and try again.'
    end

    # A Checkout that has started and not yet come back: the row holds the
    # Stripe customer and nothing else, and it was touched recently enough
    # that the session can still complete.
    def checkout_in_flight?(subscription, now: Time.current)
      return false if subscription.nil? || subscription.new_record?
      return false unless subscription.status == 'none'
      return false if subscription.stripe_customer_id.blank?
      return false if subscription.stripe_subscription_id.present? || subscription.stripe_status.present?

      subscription.updated_at.present? && subscription.updated_at > now - CHECKOUT_IN_FLIGHT_WINDOW
    end

    def stripe_backed?(subscription)
      return false if subscription.nil? || subscription.status == 'manual'

      StripeBilling::SubscriptionPolicy.live_status?(subscription.stripe_status)
    end

    # Is this account's paid access a comp, and when does it run out?
    def comp?(account)
      Plans.billing_account(account).account_subscription&.comp_expires_at.present?
    end

    # Comps whose date has passed, oldest first. CompExpiryJob's whole input.
    def due_comps(now: Time.current)
      AccountSubscription.where(comp_expires_at: ...now).order(:comp_expires_at)
    end
  end
end
