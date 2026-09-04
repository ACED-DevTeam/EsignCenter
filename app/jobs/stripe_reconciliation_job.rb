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

  Report = Struct.new(:repaired, :errors, :requeued, :duplicates, :foreign, :unlinked, :settled,
                      :manual_refunds) do
    def anything?
      repaired.any? || errors.any? || duplicates.any? || foreign.any? || unlinked.any? || settled.any? ||
        manual_refunds.any? || requeued.positive?
    end
  end

  def perform
    return if StripeBilling.api_key.blank?

    report = Report.new(repaired: [], errors: [], requeued: 0, duplicates: [], foreign: [], unlinked: [],
                        settled: [], manual_refunds: [])

    sweep(report)
    report.requeued = requeue_stuck_events

    alert(report) if report.anything?

    report
  end

  private

  # Every row this job has anything to say about: one that names a Stripe
  # subscription, and one that names none but still owes a refund on a
  # subscription it no longer names. That second kind is not a curiosity —
  # the Checkout door records exactly that debt on a row it never linked
  # anything to (a duplicate found on the way in, cancelled, its refund
  # refused), and asking only for rows with a subscription id left those
  # debts with nothing to come back for them at all.
  #
  # `status` is nullable, and NULL is not 'manual': `where.not` would quietly
  # drop every legacy row and never reconcile it again.
  def eligible_rows
    AccountSubscription.where('status IS DISTINCT FROM ?', MANUAL_STATUS)
                       .where('stripe_subscription_id IS NOT NULL OR refund_owed_subscription_id IS NOT NULL')
  end

  # One pass per row, in three steps that fail independently on purpose:
  #
  #   1. the row is repaired from Stripe. Its failure is caught HERE rather
  #      than left to the per-row rescue, because the two steps behind it are
  #      not equally poisoned by it;
  #   2. a refund the row remembers owing is settled whether or not the
  #      repair went through. It is a debt on a DEAD subscription that this
  #      step re-fetches under the row lock — it reads nothing off the row's
  #      cached columns — so a stale row is no reason to keep the customer's
  #      money for another night. Before this split, one account whose
  #      repair failed every night (a subscription deleted at Stripe, an
  #      outage on that one object) meant its owed refund was never even
  #      attempted;
  #   3. the duplicate pass, which IS skipped when the repair failed: a stale
  #      row is no basis for cancelling anything.
  def sweep(report)
    each_row(eligible_rows, report) do |subscription_row|
      # A row that names no subscription has nothing to repair and nothing to
      # measure a duplicate against: it is in this sweep for its debt alone.
      repaired = subscription_row.stripe_subscription_id.present? && repair_row(subscription_row, report)

      settle_recorded_refund(subscription_row, report)

      next unless repaired

      cancel_extra_subscriptions(subscription_row, report) if subscription_row.stripe_customer_id.present?
    end
  end

  # The repair, with its own rescue: reported exactly as the per-row rescue
  # would have reported it (one error line, one Sentry report), and answering
  # whether the row can be trusted for the duplicate pass.
  def repair_row(subscription_row, report)
    repair(subscription_row, report)

    true
  rescue StandardError => e
    record_row_error(subscription_row, report, e)

    false
  end

  # One account's Stripe error must never stop the sweep: the whole point of
  # this job is the accounts it has not looked at yet. Internal and operator
  # accounts never bill (Plans::INTERNAL): a row that somehow carries Stripe
  # ids on one is a mistake, not an instruction — never repaired, never
  # cancelled for.
  def each_row(scope, report)
    scope.find_each do |subscription_row|
      next unless subscription_row.billing_customer?

      yield subscription_row
    rescue StandardError => e
      record_row_error(subscription_row, report, e)
    end
  end

  def record_row_error(subscription_row, report, error)
    report.errors << "account #{subscription_row.account_id}: #{error.class}"

    ErrorReport.error(error, account_id: subscription_row.account_id)
  end

  # The fetch, the comparison and the write all happen under the row lock the
  # Linker owns, and the repair is only reported once apply! has actually
  # succeeded — a summary that counts a failed write as a recovery is worse
  # than no summary.
  def repair(subscription_row, report)
    repaired = StripeBilling::Linker.with_account_lock(subscription_row) do
      stripe_subscription = StripeBilling.subscription_for(subscription_row.stripe_subscription_id)
      wanted = StripeBilling::SubscriptionSync.attributes_for(subscription_row, stripe_subscription)

      next nil if drifted_attributes(subscription_row, wanted).empty?

      was = subscription_row.access_state

      StripeBilling::SubscriptionSync.apply!(subscription_row, stripe_subscription)

      { account_id: subscription_row.account_id, was:, now: subscription_row.access_state }
    end

    report.repaired << repaired if repaired
  end

  # A customer with two live subscriptions of ours is being charged twice.
  # Every live one of OURS that the row does not name goes through the
  # Linker's duplicate path (cancelled at Stripe, refunded, operator told) —
  # and only what the Linker actually cancelled is reported as cancelled.
  #
  # Which of the two survives is the survivor policy's decision, not the
  # row's: the Linker re-fetches BOTH under the row lock, and if the
  # subscription the row names is the sicker one (an `incomplete` that never
  # charged, one in dunning) the row is repointed to the one that is
  # actually collecting and the sick one is the duplicate. That is
  # resolution between two subscriptions we hold in hand, not adoption: the
  # Linker is told it may not adopt (`allow_adopt: false`), so a subscription
  # the row has never heard of is never written onto it on the strength of a
  # list — it is only named in the summary for a person. A live subscription
  # that is not ours is left alone and named too.
  def cancel_extra_subscriptions(subscription_row, report)
    live = StripeBilling::Linker.live_subscriptions(subscription_row.stripe_customer_id, subscription_row.account_id)
    own_id = subscription_row.stripe_subscription_id
    ours = live.ours.map { |subscription| StripeBilling::SubscriptionSync.field(subscription, :id) }

    note_foreign(subscription_row, live.foreign, report)

    unless ours.include?(own_id)
      settle_owed_refund(subscription_row, report)
      note_unlinked(subscription_row, ours, report)

      return
    end

    (ours - [own_id]).each do |duplicate_id|
      outcome = StripeBilling::Linker.link_and_apply!(subscription_row, duplicate_id,
                                                      notify: false, allow_adopt: false)

      next unless outcome.verdict == :duplicate_cancelled

      cancelled = outcome.cancelled_id || duplicate_id

      report.duplicates << { account_id: subscription_row.account_id, cancelled:,
                             refunded: outcome.refund&.formatted_amount }

      next if outcome.manual_note.blank?

      report.manual_refunds << { account_id: subscription_row.account_id, cancelled:, note: outcome.manual_note }
    end
  end

  # The row's own subscription is not among the live ones — and it may be one
  # WE cancelled as a duplicate and never refunded, because the attempt died
  # between the cancellation at Stripe and the money going back. Nothing else
  # will ever look at it: a dead subscription raises no more webhooks, and
  # this row is about to be left alone. So the sweep settles that debt, the
  # same way the webhook path does and through the same locked Linker call
  # (which re-fetches the subscription itself — a list is never enough to
  # move money on). Which marker is on it decides: only the one we write on a
  # duplicate created AFTER the survivor is refunded automatically.
  def settle_owed_refund(subscription_row, report)
    refund = StripeBilling::Linker.settle_owed_refund!(subscription_row, notify: false)

    return if refund.nil?

    report.settled << { account_id: subscription_row.account_id,
                        subscription: subscription_row.stripe_subscription_id,
                        refunded: refund.formatted_amount }
  end

  # The other half of the same debt, and the one the row has already moved
  # PAST: the app cancelled a duplicate, decided a person had to send its
  # money back, and adopted the live subscription the customer is paying for
  # (Review 6 N2). Nothing else will ever look at that dead subscription —
  # the row names another one now — so the note the Linker left on the row
  # (`refund_owed_subscription_id`) is retried here every night, and clears
  # itself the moment the debt is square. Independent of the customer's other
  # subscriptions, so it runs for every row, not only for the ones that turn
  # out to have a duplicate.
  def settle_recorded_refund(subscription_row, report)
    owed_id = subscription_row.refund_owed_subscription_id
    refund = StripeBilling::Linker.settle_recorded_refund!(subscription_row, notify: false)

    return if refund.nil?

    report.settled << { account_id: subscription_row.account_id, subscription: owed_id,
                        refunded: refund.formatted_amount }
  end

  # "A stranger's subscription on our customer, left alone" is reported in
  # exactly the words the Linker uses on the Checkout path — one sentence, one
  # place — and the sweep adds only its own line in the nightly summary.
  def note_foreign(subscription_row, foreign, report)
    StripeBilling::Linker.report_foreign(subscription_row, foreign)

    foreign.each do |subscription|
      report.foreign << { account_id: subscription_row.account_id, customer: subscription_row.stripe_customer_id,
                          subscription: StripeBilling::SubscriptionSync.field(subscription, :id) }
    end
  end

  # The row's own subscription is over but the customer still has a live one
  # of ours the app never linked: somebody is paying for nothing. Adopting
  # it is a decision for a person, so it is only named.
  def note_unlinked(subscription_row, ours, report)
    ours.each do |id|
      report.unlinked << { account_id: subscription_row.account_id, customer: subscription_row.stripe_customer_id,
                           subscription: id }
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
              "#{report.duplicates.size} duplicate subscription(s) cancelled, " \
              "#{report.foreign.size} foreign subscription(s) left alone, " \
              "#{report.unlinked.size} live subscription(s) not linked to any row, " \
              "#{report.settled.size} owed refund(s) settled, " \
              "#{report.manual_refunds.size} duplicate(s) awaiting a manual refund review, " \
              "#{report.requeued} stuck event(s) re-enqueued, #{report.errors.size} account(s) errored"

    ErrorReport.warning(summary, repaired: report.repaired, duplicates: report.duplicates, foreign: report.foreign,
                                 unlinked: report.unlinked, settled: report.settled,
                                 manual_refunds: report.manual_refunds, errors: report.errors)

    OperatorAlert.deliver(
      subject: 'Stripe reconciliation found work to do',
      body: "#{summary}.\n\nRepaired:\n#{format_repairs(report)}\n\n" \
            "Duplicates cancelled:\n#{format_duplicates(report)}\n\n" \
            "Foreign subscriptions left alone (not ours — check the customer in Stripe):\n" \
            "#{format_customer_subscriptions(report.foreign)}\n\n" \
            "Live subscriptions of ours not linked to any account row (somebody may be paying for nothing):\n" \
            "#{format_customer_subscriptions(report.unlinked)}\n\n" \
            "Refunds an earlier attempt owed and this sweep settled:\n#{format_settled(report)}\n\n" \
            'Duplicates cancelled that need a manual refund review (older than the subscription that ' \
            "survived — nothing was refunded automatically):\n#{format_manual_refunds(report)}\n\n" \
            "Errors:\n#{report.errors.join("\n")}\n"
    )
  end

  def format_repairs(report)
    report.repaired.map { |r| "  account #{r[:account_id]}: #{r[:was]} -> #{r[:now]}" }.join("\n")
  end

  def format_duplicates(report)
    report.duplicates.map do |d|
      line = "  account #{d[:account_id]}: cancelled #{d[:cancelled]}"

      d[:refunded] ? "#{line}, refunded #{d[:refunded]}" : line
    end.join("\n")
  end

  def format_settled(report)
    report.settled.map do |s|
      "  account #{s[:account_id]}: refund settled: #{s[:refunded]} for #{s[:subscription]}"
    end.join("\n")
  end

  def format_manual_refunds(report)
    report.manual_refunds.map { |m| "  account #{m[:account_id]}:\n#{m[:note]}" }.join("\n")
  end

  def format_customer_subscriptions(entries)
    entries.map { |e| "  account #{e[:account_id]}: #{e[:subscription]} on customer #{e[:customer]}" }.join("\n")
  end
end
