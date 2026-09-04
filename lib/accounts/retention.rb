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

    # The last of them, and the one that carries the authority: nothing
    # dormant is purged until this warning has been out for this many days
    # (K6). Named rather than `.min` at each call site, because it means
    # something — "the notice period" — and not merely "the smallest number
    # in that list".
    FINAL_WARNING_DAYS = DORMANT_WARNING_DAYS.min

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

    # THE question, asked again by AccountPurgeJob under the account's row lock
    # a moment before anything is destroyed (review batch 2, K1).
    #
    # The sweep that enqueued the job made this decision minutes — or, after a
    # retry, hours — ago, and both clocks can be stopped by somebody in the
    # meantime: an administrator presses "Cancel deletion", or a dormant
    # account's owner simply signs in. Destroying an account on the strength of
    # a stale decision is the one mistake in this whole area that cannot be
    # undone, so the answer is recomputed from the row rather than trusted.
    def purge_eligible?(account, now: Time.current)
      return false if account.nil? || account.purged?
      return false unless account.customer?
      return false if testing_child?(account)

      explicit_due?(account, now:) || dormant_purgeable?(account, now:)
    end

    # The explicit path: an administrator asked, and has not un-asked.
    def explicit_due?(account, now: Time.current)
      account.deletion_requested_at.present? &&
        account.purge_scheduled_for.present? &&
        account.purge_scheduled_for <= now
    end

    def testing_child?(account)
      AccountLinkedAccount.testing.exists?(linked_account_id: account.id)
    end

    # The dormant half. Prefiltered in SQL to accounts that COULD be a year
    # idle (an account created last month never can be, because its own
    # creation counts as activity) and that hold no paid access; the rest of
    # the rule is read row by row, because "last activity" is a maximum over
    # four different columns and saying that in SQL would hide it.
    def dormant_candidates(now: Time.current)
      dormant_scope(now:).select { |account| dormant_purgeable?(account, now:) }
    end

    # Dormant AND warned. `dormant?` alone is the arithmetic — a year of
    # silence — and on its own it would have deleted, on the very first sweep
    # after this shipped, every account that was already a year idle: no
    # 60-day letter, no 30-day letter, no 7-day letter, nothing (review batch
    # 2, K6). The computed clock has no memory of what anybody was told, so
    # the evidence is written down (accounts.dormant_warning_sent_at) and
    # three things have to be true before a row is destroyed:
    #
    #   * it is dormant by the arithmetic;
    #   * the FINAL warning actually went out, and went out at least a week
    #     ago — so a newly-noticed account gets its week whatever its dates
    #     say;
    #   * the date that warning NAMED has arrived, so nobody is deleted
    #     earlier than the day they were given.
    #   * the warning belongs to THIS dormancy, not an older one. An account
    #     can go quiet, be warned, come back to life, and go quiet again a year
    #     later; the letter from the first cycle must not authorize the second
    #     deletion, or somebody who signed in after being warned would be
    #     deleted a year later without ever hearing about it again (review
    #     batch 2, P9). A warning sent before the last thing that happened on
    #     the account is from the previous cycle, and is not evidence of
    #     anything about this one.
    def dormant_purgeable?(account, now: Time.current)
      return false unless dormant?(account, now:)
      return false if account.dormant_warning_sent_at.blank?
      return false if account.dormant_warning_sent_at > now - FINAL_WARNING_DAYS.days
      return false if account.dormant_warning_sent_at < last_activity_at(account)
      return false if account.dormant_warning_for.present? && account.dormant_warning_for > now

      true
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

        purge_at = scheduled_dormant_purge_at(account, now:)
        days = due_warning_days(purge_at, now)

        next if days.nil?

        send_dormant_warning!(account, purge_at:, days:)
      rescue StandardError => e
        # One account whose mail would not go out must not stop everybody
        # else's warnings (the shape BillingLifecycle.run_dunning! uses). The
        # counter has already been given back, so the next sweep tries again.
        ErrorReport.error(e, account_id: account.id)
      end

      nil
    end

    # The date this account is actually going to be destroyed, as the customer
    # has been TOLD it — which is not always the arithmetic (K6).
    #
    # Normally it is a year after the last activity. But an account that was
    # already past that date when this feature shipped, or that crossed it
    # while the scheduler was down, has never heard from us at all; the old
    # code skipped it (`next if purge_at <= now`) and it would have been
    # deleted with no warning whatever. Such an account is given a week from
    # the day we noticed — and that date is REMEMBERED on the row, because
    # recomputing "a week from today" every night would move the deadline
    # forward for ever and send a fresh email each time.
    def scheduled_dormant_purge_at(account, now: Time.current)
      natural = dormant_purge_at(account)

      # Somebody came back. The old pin and the old letter are about a
      # dormancy that ended, so they are cleared rather than left to be
      # mistaken for evidence about the next one (P9).
      clear_stale_warning!(account)

      return natural if natural > now

      pinned = account.dormant_warning_for

      return pinned if pinned.present? && pinned > natural

      now + FINAL_WARNING_DAYS.days
    end

    # A warning is stale once the account has been used since it was sent.
    def clear_stale_warning!(account)
      return if account.dormant_warning_sent_at.blank?
      return if account.dormant_warning_sent_at >= last_activity_at(account)

      account.update_columns(dormant_warning_sent_at: nil, dormant_warning_for: nil,
                             updated_at: Time.current)
    end

    # The LATEST warning whose moment has arrived — 60 while there are 45
    # days left, 30 while there are 25, 7 at the end. Taking the smallest of
    # the arrived ones rather than the first is what makes the sequence work:
    # by day 30 the 60-day moment has also arrived, and picking that one
    # would find its counter already spent and send nothing at all.
    def due_warning_days(purge_at, now)
      DORMANT_WARNING_DAYS.select { |days| purge_at - days.days <= now }.min
    end

    # `deliver_now!` rather than `deliver_later!`, and this is the whole of R5.
    #
    # The stamp below is the evidence the purge relies on — "this customer was
    # told, a week ago, that this was coming" — and enqueueing a job is not
    # evidence of anything: the job can fail permanently afterwards, and the
    # purge would go ahead a week later on a letter nobody ever received.
    # Delivering inline means the stamp is written only once the mail server
    # has actually taken the message; a delivery that raises leaves the stamp
    # unset and the counter released, so the next sweep tries again and the
    # account is not purgeable in the meantime.
    #
    # The cost is bounded: this is a nightly sweep over the handful of
    # accounts that cross a warning boundary on any given day, not a queue.
    def send_dormant_warning!(account, purge_at:, days:)
      claim(account, "dormant:#{purge_at.to_date}:#{days}") do
        AccountMailer.dormant_warning(account, days_left: days, purge_at:).deliver_now!

        # Only the FINAL warning writes it: it is the one that starts the
        # notice period, and it is the date named in it that the purge must
        # not pre-empt.
        next unless days == FINAL_WARNING_DAYS

        account.update_columns(dormant_warning_sent_at: Time.current,
                               dormant_warning_for: purge_at,
                               updated_at: Time.current)
      end
    end

    # Send-once, keyed on the deadline the mail is about.
    #
    # The counter is claimed FIRST, because two sweeps overlapping on one
    # account must not both send; and it is RESET when the enqueue fails,
    # because otherwise one Redis wobble spends the key for ever and the
    # customer is never warned at all — which, for the 7-day letter, is the
    # difference between a deletion they saw coming and one they did not
    # (review batch 2, K10).
    #
    # Reset to zero rather than decremented (P10): a decrement is only correct
    # if this claim was the only one, and an overlapping run would leave the
    # key at 1 — consumed, with nothing sent. Zero is the honest statement of
    # what happened, which is "nobody has been warned about this date".
    #
    # Correctness here rests on the sweeps being SINGLETON cron jobs: one
    # AccountRetentionJob a night, declared in config/schedule.yml, never
    # enqueued per-account and never run in parallel with itself. The claim is
    # a guard against a double tick, not a distributed lock.
    def claim(account, key)
      return false unless AccountCounters.increment!(account.id, key, period: COUNTER_PERIOD) == 1

      begin
        yield
      rescue StandardError => e
        release(account, key)

        raise e
      end

      true
    end

    def release(account, key)
      AccountCounter.where(account_id: account.id, key:, period: COUNTER_PERIOD).update_all(value: 0)
    end

    # The one nudge before an explicit deletion goes through. The date was in
    # the confirmation mail; this says it again while there is still time to
    # press Cancel deletion.
    def schedule_deletion_reminders!(now: Time.current)
      window = now + DELETION_REMINDER_DAYS.days

      purgeable.where.not(deletion_requested_at: nil)
               .where(purge_scheduled_for: now..window).each do |account|
        claim(account, "deletion:#{account.purge_scheduled_for.to_date}:#{DELETION_REMINDER_DAYS}") do
          AccountMailer.deletion_reminder(account).deliver_later!
        end
      rescue StandardError => e
        ErrorReport.error(e, account_id: account.id)
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
