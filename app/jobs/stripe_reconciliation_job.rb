# frozen_string_literal: true

# The safety net under the webhook inbox. Webhooks get lost — an endpoint
# rotated, a deploy that dropped a delivery, a bug that marked a row failed —
# and the cost of a missed one is an account paying and not getting the
# features, or the reverse. Once a night this job asks Stripe about every
# subscription the app thinks it has, repairs whatever drifted, re-enqueues
# the events that got stuck, and tells the operator ONCE how much it had to
# fix. It never emails per account: a Stripe outage would otherwise turn into
# a thousand messages.
class StripeReconciliationJob < ApplicationJob
  queue_as :billing

  # Rows the operator granted by hand are not Stripe's to correct.
  MANUAL_STATUS = 'manual'

  Report = Struct.new(:repaired, :errors, :requeued) do
    def anything?
      repaired.any? || errors.any? || requeued.positive?
    end
  end

  def perform
    return if StripeBilling.api_key.blank?

    report = Report.new(repaired: [], errors: [], requeued: 0)

    reconcile_subscriptions(report)
    report.requeued = requeue_stuck_events

    alert(report) if report.anything?

    report
  end

  private

  def reconcile_subscriptions(report)
    scope = AccountSubscription.where.not(stripe_subscription_id: nil)
                               .where.not(status: MANUAL_STATUS)

    scope.find_each do |subscription_row|
      repair(subscription_row, report)
    rescue StandardError => e
      # One account's Stripe error must never stop the sweep: the whole point
      # of this job is the accounts it has not looked at yet.
      report.errors << "account #{subscription_row.account_id}: #{e.class}"

      ErrorReport.error(e, account_id: subscription_row.account_id)
    end
  end

  def repair(subscription_row, report)
    stripe_subscription = StripeBilling.subscription_for(subscription_row.stripe_subscription_id)
    wanted = StripeBilling::SubscriptionSync.attributes_for(subscription_row, stripe_subscription)

    return if drifted_attributes(subscription_row, wanted).empty?

    report.repaired << { account_id: subscription_row.account_id,
                         was: subscription_row.access_state,
                         now: wanted[:access_state] }

    subscription_row.with_lock do
      StripeBilling::SubscriptionSync.apply!(subscription_row, stripe_subscription)
    end
  end

  def drifted_attributes(subscription_row, wanted)
    StripeBilling::SubscriptionSync::DRIFT_ATTRIBUTES.select do |name|
      differs?(subscription_row.public_send(name), wanted[name])
    end
  end

  # Timestamps round-trip through the database at second precision, so compare
  # them as integers rather than reporting drift on every single row.
  def differs?(current, wanted)
    if current.is_a?(Time) || wanted.is_a?(Time) ||
       current.is_a?(ActiveSupport::TimeWithZone) || wanted.is_a?(ActiveSupport::TimeWithZone)
      return current&.to_i != wanted&.to_i
    end

    current != wanted
  end

  # An inbox row still `pending` or `processing` long after it was claimed
  # means the worker that had it died; a `failed` row with retries left means
  # Sidekiq's own retry chain was lost with it.
  def requeue_stuck_events
    ids = StripeEventInbox.stuck.pluck(:id) + StripeEventInbox.retryable.pluck(:id)

    ids.uniq.each { |id| ProcessStripeEventJob.perform_async(id) }

    ids.uniq.size
  end

  def alert(report)
    summary = "Stripe reconciliation: #{report.repaired.size} subscription(s) repaired, " \
              "#{report.requeued} stuck event(s) re-enqueued, #{report.errors.size} account(s) errored"

    ErrorReport.warning(summary, repaired: report.repaired, errors: report.errors)

    OperatorAlert.deliver(
      subject: 'Stripe reconciliation found work to do',
      body: "#{summary}.\n\nRepaired:\n#{format_repairs(report)}\n\nErrors:\n#{report.errors.join("\n")}\n"
    )
  end

  def format_repairs(report)
    report.repaired.map { |r| "  account #{r[:account_id]}: #{r[:was]} -> #{r[:now]}" }.join("\n")
  end
end
