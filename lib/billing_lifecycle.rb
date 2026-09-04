# frozen_string_literal: true

# What happens to a paying account when the card stops working (D43/D57).
#
# Stripe retries a failed renewal for a while and reports the subscription as
# `past_due` the whole time. That is the grace period: for PAST_DUE_GRACE_DAYS
# days the account keeps every paid feature and gets a reminder on each of the
# DUNNING_DAYS. On the last day the account is SUSPENDED — it can still be
# signed into, read, downloaded and exported, and signers with a document
# already in flight still finish it, but nothing new is created until the
# payment is settled. Paying lifts the suspension by itself.
#
# Two clocks would be a bug, so there is one: `account_subscriptions.past_due_since`,
# stamped by StripeBilling::SubscriptionSync the moment the state turns
# past_due and cleared only when the subscription is healthy again. Every
# deadline here is that stamp plus a number of days.
module BillingLifecycle
  # 14 days from the first failed renewal to suspension.
  PAST_DUE_GRACE_DAYS = 14

  # Days into the grace period that get a reminder email. Day 0 goes out from
  # the webhook itself so the customer hears within seconds; the rest come
  # from the hourly sweep. Day 13 is the last warning, the day before the
  # account is suspended.
  DUNNING_DAYS = [0, 3, 7, 13].freeze

  SUSPENSION_REASON = AccountStates::BILLING_REASON

  # Access states that mean the money is flowing again (past_due is a paid
  # state too, but it is the problem, not the recovery).
  RECOVERED_STATES = %w[trialing active canceling].freeze

  # The dedupe counters are keyed on the dunning clock itself, not on a
  # calendar month: a grace period that starts on the 25th runs into the next
  # month, and a monthly counter would reset mid-run and send day 3 twice.
  # A NEW clock (a fresh failure after a recovery) has a different key and
  # legitimately re-sends the whole sequence.
  COUNTER_PERIOD = 'lifecycle'

  module_function

  # When the grace period runs out for this row, or nil when no clock runs.
  def suspends_on(row)
    return nil if row.past_due_since.blank?

    row.past_due_since + PAST_DUE_GRACE_DAYS.days
  end

  # Pure: which dunning days this row is due for right now. Every day whose
  # deadline has passed, so a sweep that missed a tick still catches up; the
  # counters stop anything being sent twice.
  def dunning_step_for(row, now: Time.current)
    return [] if row.past_due_since.blank?

    DUNNING_DAYS.select { |day| row.past_due_since + day.days <= now }
  end

  # The hourly sweep (BillingDunningJob). Hourly rather than daily so "day
  # 14" lands within the hour rather than up to a day late.
  def run_dunning!(now: Time.current)
    AccountSubscription.where(access_state: 'past_due').find_each do |row|
      advance!(row, now:)
    rescue StandardError => e
      # One broken account must not stop the sweep for everyone else.
      ErrorReport.error(e, account_id: row.account_id)
    end

    nil
  end

  # One row's move: suspend when the grace period is over, otherwise send
  # whichever reminders are due.
  def advance!(row, now: Time.current)
    return unless manageable?(row)
    return if row.past_due_since.blank?

    account = row.account

    if (deadline = suspends_on(row)) && deadline <= now
      # Past the deadline the reminders are pointless — the thing they warned
      # about has happened, and the suspension email says so.
      suspend_for_billing!(row, account)
    else
      dunning_step_for(row, now:).each { |day| send_dunning!(row, account, day) }
    end

    nil
  end

  # Called by StripeBilling::SubscriptionSync right after a Stripe object is
  # written to the row, so every door that hears from Stripe — webhook,
  # Checkout return, nightly reconciliation — reacts the same way.
  def after_apply!(row)
    return unless manageable?(row)

    account = row.account

    case row.access_state
    when 'suspended'
      # Stripe has given up on the card (`unpaid`) or the subscription was
      # paused: there is no grace left to give.
      suspend_for_billing!(row, account)
    when 'past_due'
      # The clock has just started (or is still running): tell them now
      # rather than at the next hourly tick. Back inside the grace window a
      # billing suspension is lifted again — but only while the window is
      # actually open, or a day-14 suspension would flap every time Stripe
      # reported the same failure again.
      lift_billing_suspension!(account) if inside_grace?(row)
      send_dunning!(row, account, 0)
    else
      recover!(row, account) if RECOVERED_STATES.include?(row.access_state)
    end

    nil
  rescue StandardError => e
    # Applying the subscription is the important half and has already
    # happened: a mailer or a lock problem here must not fail the webhook.
    ErrorReport.error(e, account_id: row.account_id)

    nil
  end

  # A row this app actually bills through: its account pays for itself and is
  # a customer. Internal and operator accounts are the platform and are
  # exempt from every billing rule.
  def manageable?(row)
    row.billing_customer?
  end

  def inside_grace?(row)
    (deadline = suspends_on(row)).present? && deadline > Time.current
  end

  def send_dunning!(row, account, day)
    return unless AccountCounters.increment!(account.id, dunning_key(row, "day#{day}"),
                                             period: COUNTER_PERIOD) == 1

    BillingMailer.payment_failed(account, day:, suspends_on: suspends_on(row)).deliver_later!
  end

  # `suspend!` is itself the dedupe: it takes the account's row lock and
  # returns true only from the call that actually changed the state, so the
  # mail cannot go out twice however many sweeps or webhooks arrive at once.
  def suspend_for_billing!(_row, account)
    return unless AccountStates.suspend!(account, reason: SUSPENSION_REASON)

    BillingMailer.suspended(account).deliver_later!
  end

  # The card went through. Lift the suspension it caused and say so once —
  # once per grace period, so re-applying the same Stripe object (a duplicate
  # webhook, the nightly sweep) sends nothing.
  def recover!(row, account)
    lifted = lift_billing_suspension!(account)
    clock = ended_clock_for(row)

    return unless lifted || clock

    # Lifting is already a one-shot transition (row lock, changed-only true).
    # A clock that ended without a suspension has no such transition behind
    # it, so that half is deduped on the clock it just cleared: re-applying
    # the same Stripe object then says nothing.
    return if !lifted && AccountCounters.increment!(account.id, "dunning:#{clock.to_i}:recovered",
                                                    period: COUNTER_PERIOD) != 1

    BillingMailer.payment_recovered(account).deliver_later!
  end

  def lift_billing_suspension!(account)
    AccountStates.lift_suspension!(account, reason: SUSPENSION_REASON)
  end

  # The dunning clock this save just cleared. Read from the row's own
  # previous_changes: by the time we are called the column is already nil, and
  # a save that did not clear one is not a recovery worth an email.
  def ended_clock_for(row)
    row.previous_changes['past_due_since']&.first
  end

  def dunning_key(row, suffix)
    "dunning:#{row.past_due_since.to_i}:#{suffix}"
  end
end
