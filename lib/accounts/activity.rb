# frozen_string_literal: true

module Accounts
  # "Somebody is using this account", written down at most once a day
  # (review 8, F1).
  #
  # WHY THIS EXISTS. Accounts::Retention decides when an unused account is
  # destroyed, and until this shipped it measured "unused" entirely out of
  # Devise — the creation date, `current_sign_in_at`, `last_sign_in_at`, and
  # the date the subscription ended. Those are facts about AUTHENTICATION,
  # and authentication is the one thing this application almost never asks
  # for: sign-up turns remember-me on for everybody (User#remember_me) and
  # the remember cookie lives 730 days (config/initializers/devise.rb). A
  # person could therefore work in the app every day for a year, never move a
  # Devise timestamp, and be told by email to "simply sign in" to save an
  # account their browser was already signed in to. They would do exactly as
  # they were told and the account would still be destroyed.
  #
  # So the clock is fed a fact about USE instead: the last time a signed-in
  # member of the account made a request the application required
  # authentication for. Signer and public traffic is deliberately not counted
  # — that is the recipient's activity, not the account's — which is why the
  # stamp rides on ApplicationController#authenticate_user! rather than on a
  # callback of its own (see the comment there).
  #
  # THREE THINGS ABOUT THE WRITE, all of them deliberate:
  #
  #   * THROTTLED to one write per account per day. This runs on every
  #     authenticated request in the application, so it has to cost nothing:
  #     the value already loaded on the account object is compared first and
  #     the overwhelming majority of requests do no SQL at all. A day's
  #     resolution is 365 times finer than the year the purge measures, and
  #     the notice period is a week — nothing is decided on the difference
  #     between this morning and last night.
  #
  #   * ONE UPDATE BY PRIMARY KEY, outside any transaction and taking no lock
  #     of its own. The seat doors hold the ACCOUNT row lock and the billing
  #     doors hold the SUBSCRIPTION row lock (see the lock order written down
  #     in BillingLifecycle.park_everyone_but_one_admin!); a stamp that
  #     joined either of those queues would put a Stripe webhook behind
  #     somebody's dashboard refresh. A blind single-column UPDATE can wait
  #     behind a row lock but can never be part of a deadlock cycle, because
  #     it holds nothing else while it waits.
  #
  #   * `updated_at` IS NOT TOUCHED. That column is the row's "somebody
  #     changed a setting" clock and is read that way elsewhere. "Somebody
  #     looked at a page" is a different fact and gets its own column.
  module Activity
    # How often the stamp may be rewritten. Anything finer buys the purge
    # nothing and costs an UPDATE per request.
    THROTTLE = 1.day

    module_function

    # Records that this account is in use. Safe to call on every request.
    def record!(account, now: Time.current)
      return if account.nil?
      return unless stale?(account, now:)

      # An account whose purge has been claimed is already archived and past
      # every decision, and a purged one is a tombstone: neither is a row to
      # write "in use" onto (AccountPurgeJob). Checked after the throttle so
      # the ordinary request pays nothing for it.
      return if account.purge_started_at? || account.purged_at?

      # `update_columns` rather than `update!`: no validations, no callbacks,
      # no `updated_at`, no transaction — and it leaves the object in hand
      # CLEAN, which matters because the same account object is passed to
      # `with_lock` elsewhere in the request and a record carrying unsaved
      # changes cannot be locked at all.
      #
      # Two requests arriving in the same instant can both pass the throttle
      # and both write; they write the same timestamp to the same column, so
      # there is nothing to lose and nothing to serialise.
      account.update_columns(last_active_at: now)
    rescue StandardError => e
      # A dormancy stamp is never worth a 500 to the person browsing. The
      # write takes no lock and is not part of any transaction, so swallowing
      # it here poisons nothing; the worst case is that this account looks a
      # day quieter than it is, and it has a whole year of days to try again.
      ErrorReport.error(e, account_id: account.id)

      nil
    end

    # Has a day gone by? A NULL stamp is stale by definition — it means we
    # have never recorded a request for this account, which is the state
    # every row was in the day the column was added.
    def stale?(account, now: Time.current)
      account.last_active_at.blank? || account.last_active_at <= now - THROTTLE
    end
  end
end
