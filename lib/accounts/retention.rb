# frozen_string_literal: true

module Accounts
  # How long we keep an account nobody is using, and when we tell them (D43).
  #
  # Two clocks end in the same place — Accounts::Purge — and they are kept
  # apart because they mean different things:
  #
  #   * EXPLICIT — an administrator asked us to delete the account. The date
  #     is written on the row (`purge_scheduled_for`, 90 days out) and the
  #     customer was told it in the confirmation email. One reminder goes out
  #     a week before.
  #   * DORMANT — nobody has signed in for a year and there is no money
  #     involved. No date is stored: it is COMPUTED from the last thing that
  #     happened, so a single sign-in resets the whole clock without anything
  #     having to be cleared. Warnings go out 60, 30 and 7 days before.
  #
  # Two rules protect data that is not really abandoned:
  #   * an account with paid access is never dormant, however quiet it is;
  #   * an account that USED to pay keeps everything for a year after its
  #     subscription ended, even if nobody signs in again.
  module Retention
    # No sign-in for this long and the account is abandoned.
    DORMANT_AFTER = 1.year

    # And a cancelled paid account keeps its documents at least this long
    # after the subscription ended, whatever the sign-in dates say.
    PAID_RETENTION = 1.year

    # Days before the purge date that get a warning email.
    DORMANT_WARNING_DAYS = [60, 30, 7].freeze

    # The explicit path already told them the date in the confirmation mail;
    # this is the one nudge before it arrives.
    DELETION_REMINDER_DAYS = 7

    # Counter keys are per calendar month by default. These have to survive
    # a month boundary — a 60-day warning sent on 31 March must still stop a
    # second one on 1 April — so they are all written into one bucket.
    COUNTER_PERIOD = 'retention'

    module_function

    # Everything the nightly job does, in the order it matters: warn first
    # (an account warned today may be purged tomorrow, never the reverse),
    # then purge.
    def run!(now: Time.current)
      schedule_dormant_warnings!(now:)
      schedule_deletion_reminders!(now:)
      purge_due!(now:)
    end

    # --- who gets purged -------------------------------------------------------

    # Customer accounts that may be destroyed right now: the ones whose
    # explicit date has passed, plus the ones that have been dormant for a
    # year. Never a testing child (it goes with its parent), never an
    # already-purged row, never the platform.
    def purge_candidates(now: Time.current)
      (explicit_candidates(now:) + dormant_candidates(now:)).uniq(&:id)
    end

    def explicit_candidates(now: Time.current)
      # A NULL date is never <= now in SQL, so "nobody asked" is excluded by
      # the comparison itself.
      purgeable.where(purge_scheduled_for: ..now).to_a
    end

    # The dormant half. Prefiltered in SQL to accounts that COULD be a year
    # idle (an account created last month never can be, because its own
    # creation counts as activity) and that hold no paid access; the rest of
    # the rule is read row by row, because "last activity" is a maximum over
    # four different columns and saying that in SQL would hide it.
    def dormant_candidates(now: Time.current)
      dormant_scope(now:).select { |account| dormant?(account, now:) }
    end

    def dormant_scope(now: Time.current, horizon: DORMANT_AFTER)
      purgeable.where(created_at: ...(now - horizon))
               .where.not(id: AccountSubscription.where(access_state: Plans::PAID_ACCESS_STATES).select(:account_id))
    end

    # Customer accounts that are not already gone and are not somebody else's
    # testing corner.
    def purgeable
      Account.where(account_kind: Account::CUSTOMER_KIND, purged_at: nil)
             .where.not(id: Account.testing_child_ids)
    end

    def dormant?(account, now: Time.current)
      return false if paid_access?(account)
      return false if within_paid_retention?(account, now:)

      dormant_purge_at(account) <= now
    end

    # The date a dormant account is destroyed: a year after the last thing
    # that happened on it. Not stored anywhere — recomputed every night, so
    # one sign-in moves it a year into the future by itself.
    def dormant_purge_at(account)
      last_activity_at(account) + DORMANT_AFTER
    end

    # The last thing that happened: anybody signing in, the account being
    # created, or its subscription ending. `current_sign_in_at` and
    # `last_sign_in_at` are both read because Devise moves the first to the
    # second on the next sign-in and a session that is still open leaves only
    # the first set.
    def last_activity_at(account)
      [account.created_at,
       User.where(account_id: account.id).maximum(:current_sign_in_at),
       User.where(account_id: account.id).maximum(:last_sign_in_at),
       subscription_ended_at(account)].compact.max
    end

    def paid_access?(account)
      Plans::PAID_ACCESS_STATES.include?(account.account_subscription&.access_state)
    end

    # When the money stopped. `ended_at` is what Stripe said; `updated_at` is
    # the fallback for a row that was revoked by hand and never carried a
    # Stripe end date.
    def subscription_ended_at(account)
      row = account.account_subscription

      return nil if row.nil? || Plans::PAID_ACCESS_STATES.include?(row.access_state)

      row.ended_at || row.updated_at
    end

    # A customer who paid us keeps everything for a year after the
    # subscription ended, whether or not anybody signs in again — the promise
    # is about their documents, not about their habits.
    def within_paid_retention?(account, now: Time.current)
      row = account.account_subscription

      return false if row.nil?
      return false unless paid_history?(row)

      (row.ended_at || row.updated_at) > (now - PAID_RETENTION)
    end

    # Did this row ever represent real money? A Stripe subscription id, or an
    # end date Stripe wrote, is the evidence; a row the operator granted by
    # hand and then revoked counts too, because somebody had the paid plan.
    def paid_history?(row)
      row.stripe_subscription_id.present? || row.stripe_customer_id.present? || row.ended_at.present?
    end

    # --- warnings --------------------------------------------------------------

    # 60, 30 and 7 days before a dormant account's computed purge date. The
    # dedupe key carries the DATE it was computed for, so an account that
    # goes quiet again after a sign-in is warned about the new date properly
    # rather than being told nothing because it heard about the old one.
    def schedule_dormant_warnings!(now: Time.current)
      longest = DORMANT_WARNING_DAYS.max

      dormant_scope(now:, horizon: DORMANT_AFTER - longest.days).each do |account|
        next if paid_access?(account) || within_paid_retention?(account, now:)

        purge_at = dormant_purge_at(account)

        next if purge_at <= now

        days = due_warning_days(purge_at, now)

        next if days.nil?

        send_dormant_warning!(account, purge_at:, days:)
      end

      nil
    end

    # The LATEST warning whose moment has arrived — 60 while there are 45
    # days left, 30 while there are 25, 7 at the end. Taking the smallest of
    # the arrived ones rather than the first is what makes the sequence work:
    # by day 30 the 60-day moment has also arrived, and picking that one
    # would find its counter already spent and send nothing at all.
    def due_warning_days(purge_at, now)
      DORMANT_WARNING_DAYS.select { |days| purge_at - days.days <= now }.min
    end

    def send_dormant_warning!(account, purge_at:, days:)
      key = "dormant:#{purge_at.to_date}:#{days}"

      return unless AccountCounters.increment!(account.id, key, period: COUNTER_PERIOD) == 1

      AccountMailer.dormant_warning(account, days_left: days, purge_at:).deliver_later!
    end

    # The one nudge before an explicit deletion goes through. The date was in
    # the confirmation mail; this says it again while there is still time to
    # press Cancel deletion.
    def schedule_deletion_reminders!(now: Time.current)
      window = now + DELETION_REMINDER_DAYS.days

      purgeable.where.not(deletion_requested_at: nil)
               .where(purge_scheduled_for: now..window).each do |account|
        key = "deletion:#{account.purge_scheduled_for.to_date}:#{DELETION_REMINDER_DAYS}"

        next unless AccountCounters.increment!(account.id, key, period: COUNTER_PERIOD) == 1

        AccountMailer.deletion_reminder(account).deliver_later!
      end

      nil
    end

    # --- purging ---------------------------------------------------------------

    # One job per account, so a single account that refuses (a live
    # subscription, a broken attachment) cannot stop every other account's
    # purge, and so a retry retries one account rather than the sweep.
    def purge_due!(now: Time.current)
      purge_candidates(now:).each do |account|
        AccountPurgeJob.perform_later(account.id)
      end

      nil
    end
  end
end
