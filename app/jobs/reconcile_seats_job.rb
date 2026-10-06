# frozen_string_literal: true

# Hand back a seat nobody occupies, out of band.
#
# Stripe tells us what a subscription bills by delivering a webhook, and the
# app applies that inside the account's row lock. Asking Stripe for a CHANGE
# from in there would mean every delivery Stripe makes can start another
# outbound call, from inside the very lock that is applying it — so the
# decision is made there and the work is done here, after the transaction has
# committed (`enqueue_after_transaction_commit`).
#
# Everything it does is idempotent: BillingLifecycle.release_seats! re-reads
# the row under its own lock and does nothing unless the subscription still
# bills for more seats than the account occupies. A duplicate run, or a run
# that arrives after the hourly sweep has already dealt with it, is a no-op.
class ReconcileSeatsJob < ApplicationJob
  queue_as :billing

  # The row the webhook was applying is only committed when its transaction
  # ends; a job that started before that would read the old numbers.
  self.enqueue_after_transaction_commit = true

  def perform(account_subscription_id)
    row = AccountSubscription.find_by(id: account_subscription_id)

    return if row.nil?

    BillingLifecycle.release_seats!(row)
  end
end
