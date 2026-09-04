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

  # How long an invitation is worth something. A seat is HELD for the whole
  # week (and, on a paid account, paid for), so this is money as much as it is
  # a security window: long enough for somebody who is away for a few days,
  # short enough that a mistyped address does not bill an empty seat forever.
  INVITE_TOKEN_DAYS = 7

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

  # The hourly sweep (BillingLifecycleJob). Hourly rather than daily so "day
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

    # Whatever else this save meant, the plan it leaves behind may not have
    # room for everyone (D43).
    enforce_free_seat_limit!(row, account)

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

  # --- seats -----------------------------------------------------------------
  #
  # A seat is bought before the invitation goes out and handed back when the
  # invitation lapses or the person leaves. Handing it back is deliberately
  # asymmetric with buying it: an addition is prorated and invoiced at once
  # (the customer asked for it and sees the charge first), a reduction is
  # `proration_behavior: 'none'` — no mid-cycle credit, the NEXT invoice
  # simply bills fewer seats (D43: no prorated refunds).

  # What Stripe would charge, today, for one more seat: the prorated remainder
  # of the current billing period. Read as a PREVIEW invoice, so nothing is
  # created and nothing is charged — the customer sees the number before they
  # agree to it.
  def preview_seat_addition(row, quantity_after: row.quantity + 1)
    preview = StripeBilling.client.v1.invoices.create_preview(
      { customer: row.stripe_customer_id,
        subscription: row.stripe_subscription_id,
        subscription_details: {
          items: [{ id: row.stripe_item_id, quantity: quantity_after }],
          proration_behavior: 'always_invoice'
        } }
    )

    { quantity_after:,
      amount_cents: StripeBilling::SubscriptionSync.field(preview, :amount_due).to_i,
      currency: StripeBilling::SubscriptionSync.field(preview, :currency).to_s.presence || 'usd',
      subscription_id: row.stripe_subscription_id,
      item_id: row.stripe_item_id }
  end

  # Money as a person reads it, the same way a refund notice writes it
  # (StripeBilling::Linker::Refund#formatted_amount).
  def format_amount(cents, currency)
    dollars = format('%.2f', cents.to_i / 100.0)

    currency.to_s.casecmp('usd').zero? ? "$#{dollars}" : "#{dollars} #{currency.to_s.upcase}"
  end

  # Buy the seat. `always_invoice` charges the prorated remainder now — the
  # amount the customer was just shown — and `pending_if_incomplete` is the
  # safety catch: if the card needs a second step (3-D Secure), Stripe parks
  # the change as a `pending_update` instead of quietly leaving the
  # subscription in a half-changed state, and the caller reserves nothing.
  #
  # The idempotency key names the row, the quantity being bought and who it is
  # for, so a double-clicked confirm button buys ONE seat.
  def add_seat!(row, quantity_after:, idempotency_key:)
    StripeBilling.client.v1.subscriptions.update(
      row.stripe_subscription_id,
      { items: [{ id: row.stripe_item_id, quantity: quantity_after }],
        proration_behavior: 'always_invoice',
        payment_behavior: 'pending_if_incomplete' },
      { idempotency_key: }
    )
  end

  # Did Stripe park the change instead of making it? Then the seat is not
  # bought, however healthy the answer looked.
  def pending_update?(stripe_subscription)
    StripeBilling::SubscriptionSync.field(stripe_subscription, :pending_update).present?
  end

  # Can this row be charged for another seat at all? A rake-granted row, a
  # child account billed by its parent and a subscription Stripe no longer
  # considers live have no item to change.
  def seats_purchasable?(row)
    return false if row.nil? || !manageable?(row)
    return false if row.stripe_subscription_id.blank? || row.stripe_item_id.blank?

    StripeBilling::Linker.holds_live_subscription?(row)
  end

  # Bring the subscription's quantity down to what is actually occupied.
  # Never up — adding a seat is a decision with a charge attached and belongs
  # to the invite flow — and never below occupancy or below 1.
  def release_seats!(row)
    return false unless manageable?(row)
    return false if row.stripe_subscription_id.blank? || row.stripe_item_id.blank?
    return false unless StripeBilling::Linker.holds_live_subscription?(row)

    StripeBilling::Linker.with_account_lock(row) do
      # Inside the lock the row is re-read: a webhook that changed the
      # quantity a moment ago wins, and the target is computed from what is
      # true now rather than from what the sweep saw.
      target = [Accounts.seat_occupancy(row.account), 1].max

      next false if target >= row.quantity

      StripeBilling.client.v1.subscriptions.update(
        row.stripe_subscription_id,
        { items: [{ id: row.stripe_item_id, quantity: target }], proration_behavior: 'none' }
      )

      StripeBilling::Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)

      true
    end
  rescue Stripe::StripeError, StripeBilling::ListIncomplete, ActiveRecord::LockWaitTimeout => e
    # The seat stays paid for one more cycle, which is a billing annoyance
    # rather than a broken account: the next sweep tries again.
    ErrorReport.error(e, account_id: row.account_id)

    false
  end

  # The other half of the hourly tick: invitations that nobody accepted.
  #
  # Expiry itself is a timestamp and needs no writing — `pending` already
  # ignores an invite whose `expires_at` has passed, so the seat stops being
  # occupied the moment the clock passes it. What DOES need writing is
  # `released_at`: without it this sweep would ask Stripe to set the same
  # quantity every hour for the rest of the subscription's life.
  def expire_invites!(now: Time.current)
    AccountInvite.expired.where(released_at: nil).where(expires_at: ..now)
                 .distinct.pluck(:account_id).each do |account_id|
      release_expired_invites_for!(account_id, now:)
    rescue StandardError => e
      ErrorReport.error(e, account_id:)
    end

    nil
  end

  def release_expired_invites_for!(account_id, now: Time.current)
    account = Account.find_by(id: account_id)

    return if account.nil?

    AccountInvite.expired.where(account_id:, released_at: nil).where(expires_at: ..now)
                 .update_all(released_at: now)

    row = Plans.billing_account(account).account_subscription

    release_seats!(row) if row
  end

  # The plan no longer has room for everyone (D43). Nobody is deleted and
  # nothing is purged: one admin keeps full access and every other member is
  # marked read-only — they still sign in, read, download and export — and the
  # admin then chooses who gets the remaining seats back.
  #
  # Deliberately not run while the account is SUSPENDED for billing: that
  # state already freezes every write for everybody and is lifted the moment
  # the card goes through, whereas read-only marking is never undone
  # automatically. A subscription that really ends arrives here as 'cancelled'
  # and is handled then.
  def enforce_free_seat_limit!(row, account)
    return if row.access_state == 'suspended'
    return if Plans::PAID_ACCESS_STATES.include?(row.access_state)

    seats = Plans.seats_for(account) || 1

    return if Accounts.seat_occupancy(account) <= seats

    kept = admin_to_keep(account)
    demoted = demote_members!(account, kept)

    return if demoted.zero?

    BillingMailer.seats_reduced(account, kept:, seats:).deliver_later!
  end

  # Who keeps working: the admin who was here most recently. Somebody has to
  # be able to administer the account tomorrow, and "whoever signed in last"
  # is the closest thing to "whoever is running this account" that we can read
  # without asking. A tie (nobody has ever signed in) goes to the oldest
  # account — the person who most likely created it.
  def admin_to_keep(account)
    candidates = User.where(account_id: Accounts.seat_account_ids(account))
                     .where.not(role: :integration).active.full_access

    candidates.admins.min_by { |user| [-user.current_sign_in_at.to_i, user.id] } ||
      candidates.min_by(&:id)
  end

  def demote_members!(account, kept)
    scope = User.where(account_id: Accounts.seat_account_ids(account))
                .where.not(role: :integration).active.full_access
    scope = scope.where.not(id: kept.id) if kept

    scope.update_all(read_only_at: Time.current)
  end
end
