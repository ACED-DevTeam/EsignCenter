# frozen_string_literal: true

module Accounts
  # Deleting an account is a 90-day decision (D43).
  #
  # An administrator confirms with their password; from that moment the
  # subscription is cancelled at Stripe, the account is SUSPENDED — which in
  # this app means read-only, not gone: everyone can still sign in, read,
  # download and export (lib/account_states.rb) — and a date 90 days out is
  # written down. Any admin can change their mind before that date by signing
  # in and pressing Cancel deletion. On the date, Accounts::Purge destroys
  # everything (lib/accounts/purge.rb).
  #
  # Why suspension rather than a state of its own: the read-only layer, the
  # token refusal and the dashboard banner slot all already exist and all read
  # `suspended_at`. A second frozen state would mean teaching every one of
  # them a second thing to look at, and the first door somebody forgot would
  # be a hole. The `reason` column is what keeps the two apart, so a payment
  # going through can never lift a deletion (AccountStates.lift_suspension!
  # only lifts the reason it is asked for).
  module Deletion
    # How long the customer has to change their mind.
    WINDOW_DAYS = 90

    # Who owns the suspension this flow writes.
    SUSPENSION_REASON = 'deletion'

    # Raised when something asks to delete an account that may not be
    # deleted through this door: an internal or operator account (the
    # platform itself — an operator deletion would destroy the platform
    # signing certificate, Session 4 handoff) or a testing child, which is
    # not an account of its own but a corner of its parent.
    class NotDeletable < StandardError; end

    module_function

    # Customer accounts that stand on their own. A testing child is purged
    # WITH its parent and is never deleted by itself; internal and operator
    # accounts are the platform.
    def deletable?(account)
      return false if account.nil?
      return false unless account.customer?
      return false if account.testing?

      !account.purged?
    end

    def assert_deletable!(account)
      return true if deletable?(account)

      raise NotDeletable, "account #{account&.id.inspect} may not be deleted through the self-service door"
    end

    def purge_date(now = Time.current)
      now + WINDOW_DAYS.days
    end

    # One date format for the whole flow — the settings card, the banner, the
    # confirmation email — so the customer is never told two different-looking
    # dates for the same deadline. UTC, because the deadline is a UTC one.
    def format_date(time)
      time&.utc&.strftime('%-d %B %Y')
    end

    # Ask for the account to be deleted. Idempotent: asking twice keeps the
    # first date, because the second press of a button must never buy the
    # customer 90 more days without telling them.
    #
    # The database half runs in one transaction; the two things that talk to
    # the outside world (Stripe, mail) run AFTER it has committed. Cancelling
    # a subscription from inside the account's row lock is the shape the
    # Linker exists to avoid, and a mail server being slow must not hold a
    # transaction open.
    def request!(account, requested_by: nil)
      assert_deletable!(account)

      # "Was it already pending?" is decided INSIDE the lock and reported out
      # of it (review batch 2, K11). Read before the lock — the shape this
      # replaces — two double-clicked requests both saw "no" and both went on
      # to cancel at Stripe and mail every administrator, so the customer got
      # the same alarming email twice for one decision.
      already = ApplicationRecord.transaction do
        was_pending = account.with_lock do
          pending = account.pending_deletion?

          unless pending
            account.update!(deletion_requested_at: Time.current,
                            purge_scheduled_for: purge_date,
                            deletion_requested_by_id: requested_by&.id)
          end

          pending
        end

        suspend_for_deletion!(account)

        was_pending
      end

      account.reload

      return account if already

      cancel_subscription(account)
      AccountMailer.deletion_scheduled(account).deliver_later!
      ErrorReport.info('account deletion scheduled', account_id: account.id,
                                                     purge_scheduled_for: account.purge_scheduled_for.to_s)

      account
    end

    # Freeze the account under the DELETION reason, taking the suspension over
    # from billing if one is already there.
    #
    # The take-over matters and is not tidying. `AccountStates.suspend!` never
    # overwrites an existing suspension, so an account frozen for a failed card
    # that then asks to be deleted would keep the reason 'billing' — and the
    # next time Stripe said anything healthy about the subscription, the
    # billing sweep would lift that reason and hand a fully writable account
    # back to a customer who has asked us to delete it. There is nothing left
    # for the billing suspension to enforce anyway: the subscription was
    # cancelled a moment ago, so no money is outstanding.
    #
    # An operator's suspension is deliberately NOT taken over: an account an
    # operator froze stays frozen on the operator's terms, and the deletion
    # date sits on top of it.
    def suspend_for_deletion!(account)
      return true if AccountStates.suspend!(account, reason: SUSPENSION_REASON)

      account.with_lock do
        next false unless account.suspension_reason.to_s == BillingLifecycle::SUSPENSION_REASON

        account.update!(suspension_reason: SUSPENSION_REASON)

        true
      end
    end

    # Changed their mind. Clears the dates and lifts ONLY the deletion
    # suspension — an account that was also suspended for a failed payment
    # stays suspended for that, which is why the reason is named.
    #
    # The subscription is NOT resurrected: Stripe cancellations are not
    # reversible from here, and the honest thing is to tell the customer they
    # are on the free plan and can subscribe again. The billing page already
    # says so.
    # Returns true only when a deletion was actually called off. False means
    # there was nothing to call off, or — the case that matters — the purge has
    # already claimed the account and there is no longer anything whole to come
    # back to (review batch 2, P1). That check is made INSIDE the lock and
    # re-read there, because the claim can land between a caller deciding to
    # cancel and this method running; saying "your deletion has been
    # cancelled" over an account that is at that moment being emptied would be
    # the worst lie this feature could tell.
    def cancel!(account)
      return false if account.nil? || !account.pending_deletion?

      cancelled = account.with_lock do
        next false if account.purge_claimed?
        next false unless account.pending_deletion?

        account.update!(deletion_requested_at: nil, purge_scheduled_for: nil, deletion_requested_by_id: nil)

        true
      end

      return false unless cancelled

      AccountStates.lift_suspension!(account, reason: SUSPENSION_REASON)

      account.reload

      AccountMailer.deletion_cancelled(account).deliver_later!
      ErrorReport.info('account deletion cancelled', account_id: account.id)

      true
    end

    # Stop charging the customer the moment they ask to leave. Stripe being
    # unreachable must not fail the deletion — the account is already frozen
    # and dated — so a failure becomes a retrying job instead.
    def cancel_subscription(account)
      cancel_subscription!(account)
    rescue StandardError => e
      ErrorReport.error(e, account_id: account.id)

      CancelDeletedSubscriptionJob.perform_later(account.id)

      false
    end

    # The cancel itself, in the same two steps the Linker uses for a duplicate
    # (lib/stripe_billing/linker.rb): stamp the marker into METADATA first —
    # only our secret key can write it, so it is the app's durable memory of
    # why the subscription ended — then cancel, repeating the marker in
    # `cancellation_details.comment` for whoever opens the Stripe dashboard.
    #
    # The marker is a THIRD value under the same metadata key the duplicate
    # path reads, and this is the point of it: that path only ever moves money
    # for 'duplicate' and only ever asks a person about 'duplicate-manual', so
    # a subscription stamped 'account-deletion' can never be mistaken for
    # either. A customer who chooses to leave is not owed a refund of the
    # month they used.
    #
    # Returns true when Stripe was actually asked, false when there was
    # nothing live to cancel. Raises when Stripe refuses for any reason other
    # than "it is already gone", so the retrying job tries again.
    def cancel_subscription!(account)
      row = account.account_subscription

      return false if row.nil? || row.stripe_subscription_id.blank?
      return false unless StripeBilling::Linker.holds_live_subscription?(row)

      subscription_id = row.stripe_subscription_id

      mark_at_stripe!(subscription_id)

      StripeBilling.client.v1.subscriptions.cancel(
        subscription_id, { cancellation_details: { comment: StripeBilling::ACCOUNT_DELETION_MARKER } }
      )

      true
    rescue Stripe::InvalidRequestError => e
      raise unless StripeBilling::Linker.already_gone?(e, row.stripe_subscription_id)

      Rails.logger.info("Subscription #{row.stripe_subscription_id} was already gone (#{e.message})")

      false
    end

    # Keyed idempotently on the subscription, so a retry after a half-finished
    # attempt writes one marker rather than two. Stripe refusing the key
    # outright (same key, different body — the timestamp moved) means the
    # write already landed, and the cancel behind it is what still has to
    # happen.
    def mark_at_stripe!(subscription_id)
      StripeBilling.client.v1.subscriptions.update(
        subscription_id,
        { metadata: { StripeBilling::DUPLICATE_CANCEL_METADATA_KEY => StripeBilling::ACCOUNT_DELETION_METADATA,
                      StripeBilling::DUPLICATE_CANCEL_METADATA_AT_KEY => Time.now.to_i.to_s } },
        { idempotency_key: "mark-account-deletion-#{subscription_id}" }
      )

      true
    rescue Stripe::IdempotencyError
      true
    end
  end
end
