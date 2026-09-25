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

  # Written onto an inbox row whose claim this sweep released, so the row
  # itself says why it is `failed` when nothing ever raised.
  STALE_CLAIM_NOTE = 'claim released by reconciliation: the worker holding this event ' \
                     "did not finish within #{StripeEventInbox::STALE_CLAIM_AFTER.inspect}".freeze

  # How long the row-by-row half of the sweep may run before it stops for the
  # night (checkpoint 8, C10).
  #
  # The sweep is serial and asks Stripe at least twice per row — a re-fetch of
  # the subscription and a list of the customer's subscriptions — so its
  # runtime grows with the customer base and nothing bounded it. At a few
  # hundred milliseconds a row that is fine at a thousand rows and a job that
  # never finishes at fifty thousand: it would still be running when the next
  # night's copy started, holding account locks against the day's real
  # traffic.
  #
  # So it is a budget, not a row cap: what matters is wall-clock time, and a
  # slow Stripe is exactly when the sweep must stop early rather than run all
  # morning. Twenty minutes is comfortably longer than a healthy full sweep
  # and comfortably shorter than the gap to any other scheduled job. When it
  # runs out the sweep records the id it reached, alerts, and the next night
  # carries on after that id (StripeReconciliationState) — so a platform too
  # big for one night is still fully swept, a slice at a time, instead of
  # having its first N accounts swept every night and the rest never.
  SWEEP_BUDGET = 20.minutes

  # How many rows one run may downgrade because Stripe says their subscription
  # is gone (review 1, H2).
  #
  # `resource_missing` is what Stripe answers for a subscription that has been
  # deleted — and equally for every id we hold after a key is rotated into a
  # different Stripe account, or a live/test mix-up. Deleting subscriptions
  # outright is rare and one-at-a-time; a key that no longer owns our objects
  # is not. So the sweep will settle a few and then stop settling: past this
  # many, the rest are named for a person and nothing else is downgraded. The
  # cost of being cautious is a day's delay on a genuine cancellation; the
  # cost of not being is the whole paying customer base on the free plan.
  VANISHED_LIMIT = 3

  # Raised when the key cannot even find the CUSTOMER a row names. A deleted
  # subscription leaves its customer behind, so a customer that is missing too
  # means the key is not looking at our Stripe account at all. Nothing is
  # downgraded on that; the sweep stops where it is and says so loudly.
  class KeyMismatch < StandardError; end

  Report = Struct.new(:repaired, :errors, :requeued, :duplicates, :foreign, :unlinked, :settled,
                      :manual_refunds, :vanished, :vanished_skipped, :key_mismatch, :rows, :stopped_after) do
    def anything?
      repaired.any? || errors.any? || duplicates.any? || foreign.any? || unlinked.any? || settled.any? ||
        manual_refunds.any? || vanished.any? || vanished_skipped.any? || key_mismatch.present? ||
        requeued.positive? || stopped_after.present?
    end
  end

  class << self
    # A `processing` row nobody is coming back for, handed back to `failed`
    # so a worker may claim it again. Back to `failed`, not to `pending`: the
    # attempt that worker spent really was spent, so the row keeps its
    # `attempts` and stays inside the same five-attempt budget every other
    # failure obeys. `update_all`, so nothing about the stored bytes can be
    # touched on the way through.
    #
    # A class method because the operator console releases exactly one row
    # this way (a Retry on a stuck event) and the claim logic must have one
    # home, not two.
    #
    # THE STALENESS IS DECIDED BY THIS WRITE, not by whatever the caller
    # selected a moment earlier (review 8, D6). The nightly sweep read the
    # stale ids and then passed a bare `where(id: ...)` back in, so a row a
    # live worker had claimed in the meantime was released out from under it —
    # two workers on one Stripe event, and the note on the row saying nobody
    # owned it. `scope` narrows WHICH rows may be released; it can no longer
    # widen WHEN one may be.
    def release_stale_claims!(scope = StripeEventInbox.all)
      StripeEventInbox.stale_claims.merge(scope)
                      .update_all(status: StripeEventInbox::FAILED, last_error: STALE_CLAIM_NOTE,
                                  updated_at: Time.current)
    end

    # The one way an inbox row is handed back to Sidekiq. Returns how many.
    def requeue!(ids)
      ids = Array(ids).uniq

      ids.each { |id| ProcessStripeEventJob.perform_async(id) }

      ids.size
    end
  end

  def perform
    SchedulerStamps.record!('stripe_reconciliation') do
      next if StripeBilling.api_key.blank?

      StripeBilling::PackPurchases.reconcile!

      report = Report.new(repaired: [], errors: [], requeued: 0, duplicates: [], foreign: [], unlinked: [],
                          settled: [], manual_refunds: [], vanished: [], vanished_skipped: [],
                          key_mismatch: nil, rows: 0, stopped_after: nil)

      sweep(report)
      report.requeued = requeue_stuck_events

      alert(report) if report.anything?

      # Kept for the operator console's billing tab whether or not anything
      # happened: "last night's sweep found nothing" is exactly as useful to
      # read as a list of repairs, and a report that only appears on busy
      # nights makes a silent sweep indistinguishable from a dead one.
      StripeReconciliationState.record_report!(report)

      report
    end
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

  # Where this sweep starts: after the row the last one stopped at, or at the
  # beginning when the last one finished. Ordered by id, because "carry on
  # after this id" only means anything over a stable order.
  def rows_to_sweep
    resume_after = StripeReconciliationState.cursor

    resume_after ? eligible_rows.where(id: (resume_after + 1)..) : eligible_rows
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
  #
  # Bounded by SWEEP_BUDGET, and resumed from where the last run stopped.
  def sweep(report)
    each_row(rows_to_sweep, report) do |subscription_row|
      # A row that names no subscription has nothing to repair and nothing to
      # measure a duplicate against: it is in this sweep for its debt alone.
      repaired = subscription_row.stripe_subscription_id.present? && repair_row(subscription_row, report)

      settle_recorded_refund(subscription_row, report)

      cancel_extra_subscriptions(subscription_row, report) if repaired &&
                                                              subscription_row.stripe_customer_id.present?
    end

    settle_cursor!(report)
  rescue KeyMismatch => e
    # The one failure that stops the whole sweep rather than one row: the key
    # is not looking at our Stripe account, so nothing it says about any row
    # can be acted on. The cursor is deliberately left where it was — this run
    # proved nothing about the rows it had reached.
    report.key_mismatch = e.message

    ErrorReport.error(e)
  end

  def out_of_budget?(started)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= SWEEP_BUDGET.to_i
  end

  # The cursor is the whole of the resume: an id to carry on after, or
  # nothing at all once a sweep has reached the end. Cleared on a completed
  # run so a platform that shrinks back under the budget stops resuming from
  # a stale position forever.
  def settle_cursor!(report)
    StripeReconciliationState.cursor = report.stopped_after
  end

  # The repair, with its own rescue: reported exactly as the per-row rescue
  # would have reported it (one error line, one Sentry report), and answering
  # whether the row can be trusted for the duplicate pass.
  def repair_row(subscription_row, report)
    repair(subscription_row, report)

    true
  rescue Stripe::InvalidRequestError => e
    raise unless vanished_at_stripe?(e)

    # The id THIS fetch asked about, carried into the settlement: by the time
    # the lock is granted the row may name a different subscription entirely
    # (a webhook adopted one in between), and cancelling whatever the row
    # happens to hold on the strength of a 404 about another id is how a live
    # subscription gets downgraded.
    settle_vanished_subscription(subscription_row, report, subscription_row.stripe_subscription_id)

    false
  rescue StandardError => e
    record_row_error(subscription_row, report, e)

    false
  end

  # Stripe's 404 for an object it does not have, told apart from every other
  # invalid request (checkpoint 8, C5). Only this one code means "gone"; a
  # malformed request or a permissions problem is still a bug or an outage
  # and stays a transient error.
  def vanished_at_stripe?(error)
    error.code.to_s == StripeBilling::Linker::RESOURCE_MISSING
  end

  # The subscription the row names is not at Stripe at all — deleted outright
  # rather than cancelled, which Stripe allows in test mode and support can
  # do in live. The row used to keep whatever access state it last had
  # forever, because every night's 404 was filed as one more transient error
  # and the next night filed it again: an account on the paid plan with
  # nothing paying for it, indefinitely.
  #
  # It takes the ordinary cancelled transition instead (SubscriptionSync
  # .apply_vanished!) — free access, a D43 prospective free month, no purge —
  # under the same row lock every other repair uses. It is named in the
  # nightly report, and the report's own alert is the operator alert: a
  # per-account email here would be one per row on the night a Stripe
  # migration removed a batch of them, which is the noise this job exists to
  # avoid.
  def settle_vanished_subscription(subscription_row, report, subscription_id)
    return if refuse_vanished_over_cap(subscription_row, report, subscription_id)

    # A row that names no customer can prove nothing either way: not that the
    # subscription is really gone, and not that the key is wrong. It is
    # reported and skipped — stopping the whole sweep on it would let one
    # legacy row starve every account behind it, every night (review 1 loop 2).
    if subscription_row.stripe_customer_id.blank?
      return skip_vanished(report, subscription_row, subscription_id,
                           'the row names no Stripe customer, so nothing can confirm the subscription is gone')
    end

    confirm_key_owns_customer!(subscription_row)

    was = subscription_row.access_state
    applied = apply_vanished_under_lock(subscription_row, subscription_id)

    unless applied
      return skip_vanished(report, subscription_row, subscription_id, 'the row now holds a different subscription')
    end

    report.vanished << { account_id: subscription_row.account_id, subscription: subscription_id, was:,
                         now: subscription_row.access_state }

    ErrorReport.warning("Stripe no longer has subscription #{subscription_id} " \
                        "(account #{subscription_row.account_id}); the row was cancelled",
                        account_id: subscription_row.account_id)
  rescue KeyMismatch
    raise
  rescue StandardError => e
    record_row_error(subscription_row, report, e)
  end

  # Past the cap this run downgrades nothing more. The rest are named in the
  # report and left exactly as they are, for a person to look at.
  def refuse_vanished_over_cap(subscription_row, report, subscription_id)
    return false if report.vanished.size < VANISHED_LIMIT

    skip_vanished(report, subscription_row, subscription_id,
                  "more than #{VANISHED_LIMIT} subscriptions went missing in one run")

    true
  end

  def skip_vanished(report, subscription_row, subscription_id, reason)
    report.vanished_skipped << { account_id: subscription_row.account_id, subscription: subscription_id, reason: }

    nil
  end

  # A subscription really deleted at Stripe leaves its CUSTOMER behind. So
  # before anything is downgraded, the customer the row names is fetched: it
  # answering normally is what turns "we cannot find this id" into "this
  # subscription is gone". A customer that is missing too means the key is not
  # looking at our Stripe account — a rotated key, a live/test mix-up — and on
  # that reading every id we hold is missing. Nothing is downgraded then; the
  # sweep stops.
  def confirm_key_owns_customer!(subscription_row)
    customer_id = subscription_row.stripe_customer_id

    StripeBilling.client.v1.customers.retrieve(customer_id)

    nil
  rescue Stripe::InvalidRequestError => e
    raise unless vanished_at_stripe?(e)

    raise KeyMismatch, "the configured Stripe key cannot find customer #{customer_id} either " \
                       "(account #{subscription_row.account_id}) — it is not this Stripe account's key. " \
                       'Nothing was downgraded.'
  end

  # The cancellation, bound to the exact subscription that 404'd: the row is
  # re-read under its own lock and left alone if it has moved on.
  def apply_vanished_under_lock(subscription_row, subscription_id)
    StripeBilling::Linker.with_account_lock(subscription_row) do
      next false unless subscription_row.stripe_subscription_id == subscription_id

      StripeBilling::SubscriptionSync.apply_vanished!(subscription_row)

      true
    end
  end

  # One account's Stripe error must never stop the sweep: the whole point of
  # this job is the accounts it has not looked at yet. Internal and operator
  # accounts never bill (Plans::INTERNAL): a row that somehow carries Stripe
  # ids on one is a mistake, not an instruction — never repaired, never
  # cancelled for.
  #
  # The wall-clock budget lives here rather than in the block, so it is asked
  # on EVERY row — including one that raised. A row that failed slowly cost
  # the sweep the same minute a row that succeeded did, and a stream of
  # erroring accounts is exactly when a runaway sweep is most likely. It is
  # asked AFTER the row, never before: a run whose budget is already gone
  # must still leave the platform one row better off than it found it, or the
  # sweep never makes progress at all.
  def each_row(scope, report)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    scope.find_each do |subscription_row|
      begin
        yield subscription_row if subscription_row.billing_customer?
      rescue KeyMismatch
        raise
      rescue StandardError => e
        record_row_error(subscription_row, report, e)
      end

      report.rows += 1

      next unless out_of_budget?(started)

      report.stopped_after = subscription_row.id

      break
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

  # An inbox row still `pending` long after the endpoint stored it means its
  # enqueue was lost; a `failed` row with retries left means Sidekiq's own
  # retry chain was lost with it; and a row still `processing` long after it
  # was claimed means the worker that had it died.
  #
  # That last kind has to be RELEASED before it is re-enqueued (checkpoint 7,
  # P1): the job's claim is a compare-and-set over `pending`/`failed`, so a
  # row left `processing` is refused by every worker that picks it up. This
  # sweep is the only thing that ever decides a worker died, so it is the
  # only thing that may hand the row back.
  def requeue_stuck_events
    # The rows this sweep releases are enqueued whatever their timestamps say:
    # releasing one sets `updated_at` to now, and `retryable`'s window would
    # then hold back the very row this sweep just decided nobody owns.
    released = StripeEventInbox.stale_claims.ids

    # The predicate travels with the write (see release_stale_claims!): an id
    # in this list that a worker has claimed since it was read is left alone,
    # and re-enqueuing it below costs nothing — the claim is a compare-and-set
    # over pending/failed, so the live worker keeps it.
    self.class.release_stale_claims!(StripeEventInbox.where(id: released))

    self.class.requeue!(released + StripeEventInbox.stuck.pluck(:id) + StripeEventInbox.retryable.pluck(:id))
  end

  def alert(report)
    ErrorReport.warning(summary_of(report), repaired: report.repaired, duplicates: report.duplicates,
                                            foreign: report.foreign, unlinked: report.unlinked,
                                            settled: report.settled, manual_refunds: report.manual_refunds,
                                            vanished: report.vanished, vanished_skipped: report.vanished_skipped,
                                            key_mismatch: report.key_mismatch, errors: report.errors)

    OperatorAlert.deliver(subject: 'Stripe reconciliation found work to do', body: alert_body(report))
  end

  def summary_of(report)
    "Stripe reconciliation: #{report.repaired.size} subscription(s) repaired, " \
      "#{report.duplicates.size} duplicate subscription(s) cancelled, " \
      "#{report.foreign.size} foreign subscription(s) left alone, " \
      "#{report.unlinked.size} live subscription(s) not linked to any row, " \
      "#{report.settled.size} owed refund(s) settled, " \
      "#{report.manual_refunds.size} duplicate(s) awaiting a manual refund review, " \
      "#{report.vanished.size} subscription(s) Stripe no longer has, " \
      "#{report.vanished_skipped.size} left alone for a person, " \
      "#{report.requeued} stuck event(s) re-enqueued, #{report.errors.size} account(s) errored"
  end

  def alert_body(report)
    "#{summary_of(report)}.\n\nRepaired:\n#{format_repairs(report)}\n\n" \
      "Duplicates cancelled:\n#{format_duplicates(report)}\n\n" \
      "Foreign subscriptions left alone (not ours — check the customer in Stripe):\n" \
      "#{format_customer_subscriptions(report.foreign)}\n\n" \
      "Live subscriptions of ours not linked to any account row (somebody may be paying for nothing):\n" \
      "#{format_customer_subscriptions(report.unlinked)}\n\n" \
      "Refunds an earlier attempt owed and this sweep settled:\n#{format_settled(report)}\n\n" \
      'Duplicates cancelled that need a manual refund review (nothing was refunded automatically ' \
      "— see each note):\n#{format_manual_refunds(report)}\n\n" \
      'Subscriptions Stripe no longer has (the row was cancelled and the account is on the free ' \
      "plan):\n#{format_vanished(report)}\n\n" \
      'Subscriptions Stripe could not find that were NOT downgraded (a person has to decide):' \
      "\n#{format_vanished_skipped(report)}\n\n" \
      "#{key_mismatch_line(report)}#{budget_line(report)}Errors:\n#{report.errors.join("\n")}\n"
  end

  def format_vanished(report)
    report.vanished.map { |v| "  account #{v[:account_id]}: #{v[:subscription]} (#{v[:was]} -> #{v[:now]})" }
          .join("\n")
  end

  def format_vanished_skipped(report)
    report.vanished_skipped.map { |v| "  account #{v[:account_id]}: #{v[:subscription]} — #{v[:reason]}" }
          .join("\n")
  end

  # The loudest line the summary has, and it goes first: a key that cannot see
  # our own Stripe objects makes every other number in the report meaningless.
  def key_mismatch_line(report)
    return '' if report.key_mismatch.blank?

    "STOPPED: #{report.key_mismatch}\nCheck STRIPE_SECRET_KEY before anything else.\n\n"
  end

  # Said out loud rather than left to be inferred from a short list: a sweep
  # that stopped early has NOT looked at the accounts after this id tonight,
  # and whoever reads the summary has to know that before they conclude
  # anything from it.
  def budget_line(report)
    return '' if report.stopped_after.blank?

    "Budget exhausted after #{report.rows} row(s), at account_subscription #{report.stopped_after}. " \
      "Tomorrow's sweep carries on after that row.\n\n"
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
