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
      # A missed day-13 tick still owes the final reminder. Its existing
      # claim prevents a second mail on later sweeps.
      #
      # `late: true` because the deadline is behind us, not ahead: this is the
      # same letter arriving in the same tick as the suspension, and the
      # ordinary day-13 wording ("on <date> the account is suspended", and
      # "nothing has changed on your account yet") would be flatly untrue by
      # the time it landed.
      send_dunning!(row, account, 13, late: true)
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

    # An account whose purge has been claimed is past every one of these
    # decisions (review batch 2, R2): there is no suspension worth lifting, no
    # seat worth reconciling, and no customer left to write to. Stripe's facts
    # have already been written to the row by SubscriptionSync — which forced
    # the access state to `cancelled` and told a person about it — and this is
    # the half that would otherwise act on them.
    return if account&.purge_claimed?

    # Three steps, in this order, each in its own rescue. Applying the
    # subscription is the important half and has already happened by the time
    # we are called, so nothing here may fail the webhook — and, just as
    # important, no step may swallow the one before it. The STATE goes first
    # because it decides whether the account can work at all; then the seats,
    # which decide who may write; and mail last, because it is the only step
    # that talks to the outside world and therefore the likeliest to fail.
    #
    # Nothing here asks Stripe for anything. When the subscription turns out
    # to bill for more seats than the account occupies, the hand-back is
    # handed to a JOB that runs once this transaction has committed
    # (ReconcileSeatsJob): an outbound write from in here would let every
    # delivery Stripe makes start another call to Stripe, inside the very
    # lock that is applying it.
    transition = guarded(row) { apply_state_transition!(row, account) }

    guarded(row) { enforce_free_seat_limit!(row, account) }
    # BEFORE the hand-back, and that order is the whole of checkpoint 7's B1:
    # a seat that arrives late because the customer finished a card step is
    # not drift, it is the purchase they made. Promoting the parked
    # invitation makes it occupancy, and the hand-back below then sees a seat
    # that is occupied and leaves it alone.
    guarded(row) { promote_parked_invites!(row, account) }
    guarded(row) { schedule_seat_reconciliation(row) }
    guarded(row) { send_state_mail!(row, account, transition) }

    nil
  end

  # Stripe has just said what the subscription bills. Was anybody waiting for
  # exactly that? A seat purchase Stripe parked for a card step (3-D Secure)
  # left a PARKED invitation behind, holding no seat and mailed to nobody; the
  # subscription now billing for the quantity it was bought at is the proof
  # that the customer finished the step and the money moved. So the invitation
  # they paid for is written properly and sent — instead of the seat being
  # handed straight back with no credit and no explanation (checkpoint 7, B1).
  #
  # A purchase in flight on THIS thread is a different thing entirely: the
  # invitation for it is written by the buyer a few lines later, under the
  # same lock, and there is nothing parked to promote.
  def promote_parked_invites!(row, account)
    return if changing_seats?
    return if account.nil?

    AccountInvites.promote_parked!(account, quantity: row.quantity)
  end

  # Stripe has just said what the subscription bills. If that is more than the
  # account occupies, ask for the difference back — the job does the asking,
  # a moment later and outside this lock. This is what catches a seat the
  # customer's card step added days after we gave up on it: the seat exists,
  # the invitation it would have held was never written, and nothing else
  # would think to ask for it back until the hourly sweep came round.
  def schedule_seat_reconciliation(row)
    # A seat change already in flight on this thread is not a second thing to
    # react to, it is the same decision arriving back through the door it left
    # by — and acting on it is a loop. Two of them, in fact: the hand-back
    # applies the subscription Stripe gives back, which would schedule another
    # hand-back; and a PURCHASE is holding one more seat than the account
    # occupies for the moment between Stripe agreeing and the invitation being
    # written, which would have the seat taken straight back off the customer
    # who just paid for it.
    return if changing_seats?
    return unless StripeBilling::Linker.holds_live_subscription?(row)
    return if row.stripe_item_id.blank?
    return if row.quantity <= Accounts.seat_occupancy(row.account)

    ReconcileSeatsJob.perform_later(row.id)
  end

  # Marks the thread as "a seat change is in flight" for the length of the
  # block. Held by the hand-back and by the buyer (AccountInvitesController),
  # which are the two places that change a seat count and then apply Stripe's
  # answer to it.
  def changing_seats
    previous = Thread.current[:billing_lifecycle_changing_seats]
    Thread.current[:billing_lifecycle_changing_seats] = true

    yield
  ensure
    Thread.current[:billing_lifecycle_changing_seats] = previous
  end

  def changing_seats?
    Thread.current[:billing_lifecycle_changing_seats].present?
  end

  # One step of a state change, on its own: a failure is reported and the
  # next step still runs.
  def guarded(row)
    yield
  rescue StandardError => e
    ErrorReport.error(e, account_id: row.account_id)

    nil
  end

  # Freeze the account, or unfreeze it. Returns what actually changed, so the
  # mail step knows whether there was a transition behind it.
  def apply_state_transition!(row, account)
    case row.access_state
    when 'suspended'
      # Stripe has given up on the card (`unpaid`) or the subscription was
      # paused: there is no grace left to give.
      { suspended: AccountStates.suspend!(account, reason: SUSPENSION_REASON) }
    when 'past_due'
      # Back inside the grace window a billing suspension is lifted again —
      # but only while the window is actually open, or a day-14 suspension
      # would flap every time Stripe reported the same failure again.
      { lifted: inside_grace?(row) && lift_billing_suspension!(account) }
    else
      # Every other state, and this is the case that used to be missed:
      # Stripe cancels a subscription it has given up on about a week after
      # our day-14 suspension, and the row lands on `cancelled`. There is
      # nothing left to collect, so the suspension has no more work to do —
      # leaving it in place turned the account into a free account that could
      # never write again, forever. Recovering states lift it for the happy
      # reason; `cancelled` (and a row with no state at all) lifts it because
      # the debt it was enforcing no longer exists.
      { lifted: lift_billing_suspension!(account) }
    end
  end

  # What the customer is told, decided after the state has actually moved.
  def send_state_mail!(row, account, transition)
    transition ||= {}

    case row.access_state
    when 'suspended' then send_suspension_mail!(row, account, transition[:suspended])
    when 'past_due' then send_dunning!(row, account, 0)
    else recover!(row, account, transition[:lifted]) if RECOVERED_STATES.include?(row.access_state)
    end
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

  # One reminder per day per dunning clock — and never a day spent on a mail
  # that did not actually go (review 7, A4).
  #
  # The counter is claimed first, because two ticks overlapping on one account
  # must not both send. But it used to be spent and then forgotten about: an
  # enqueue that raised (a Redis wobble is the ordinary way) left the key
  # consumed with nothing sent, and nothing ever sends that day again. On day
  # 13 that is the last word before the account is suspended, so the customer
  # would go silent from day 7 straight to a frozen account.
  #
  # So a failed hand-off RELEASES the claim, and the next hourly tick offers
  # the same day again (`dunning_step_for` re-offers every day whose deadline
  # has passed). Reset to zero rather than decremented, for the same reason
  # the dormancy warnings do it (Accounts::Retention#claim): a decrement is
  # only right if this claim was the only one. The error is reported and
  # swallowed — one account's mail server must not stop the sweep for
  # everybody else.
  def send_dunning!(row, account, day, late: false)
    key = dunning_key(row, "day#{day}")

    return unless AccountCounters.increment!(account.id, key, period: COUNTER_PERIOD) == 1

    begin
      BillingMailer.payment_failed(account, day:, late:, suspends_on: suspends_on(row)).deliver_later!
    rescue StandardError => e
      release_counter(account, key)
      ErrorReport.error(e, account_id: account.id)
    end

    nil
  end

  def release_counter(account, key)
    AccountCounter.where(account_id: account.id, key:, period: COUNTER_PERIOD).update_all(value: 0)
  end

  # The hourly sweep's own suspension: move the state, then say so.
  def suspend_for_billing!(row, account)
    suspended = AccountStates.suspend!(account, reason: SUSPENSION_REASON)

    send_suspension_mail!(row, account, suspended)
  end

  # One suspension email per dunning clock. `suspend!` is a one-shot
  # transition, which was the only dedupe — but a Stripe wobble is more than
  # one honest transition on the SAME clock: `unpaid`, back to `past_due`
  # inside the grace window (which lifts the suspension), then `unpaid`
  # again, and the customer heard about the same suspension twice. The
  # counter is keyed on the clock itself, so a genuinely new failure after a
  # real recovery still says it again. A suspension with no clock behind it
  # (Stripe paused a perfectly healthy subscription) has nothing to key on,
  # and there the transition is still the dedupe.
  def send_suspension_mail!(row, account, suspended)
    # Only ever about OUR suspension, and only when there is one. `suspend!`
    # answers false in three different situations and they are not the same
    # thing: the account was already suspended for billing (a repeat — the
    # counter below is what dedupes that), somebody ELSE's suspension is in
    # the way (an operator's, and a billing email about that one would be a
    # lie), or the transition failed outright (nothing happened, so there is
    # nothing to announce — and the counter must not be spent on it).
    return unless suspended || suspended_for_billing?(account)

    if row.past_due_since.present?
      return unless AccountCounters.increment!(account.id, dunning_key(row, 'suspended'),
                                               period: COUNTER_PERIOD) == 1
    elsif !suspended
      return
    end

    BillingMailer.suspended(account).deliver_later!
  end

  # Is the account frozen right now, and is it OUR doing? Read from the
  # DATABASE, not from the object in hand: a `suspend!` that raised part-way
  # leaves the in-memory row carrying values that were never written, and
  # announcing a suspension that does not exist is worse than saying nothing.
  def suspended_for_billing?(account)
    fresh = Account.find_by(id: account.id)

    fresh.present? && fresh.suspended_at.present? && fresh.suspension_reason.to_s == SUSPENSION_REASON
  end

  # The card went through. Lift the suspension it caused and say so once —
  # once per grace period, so re-applying the same Stripe object (a duplicate
  # webhook, the nightly sweep) sends nothing.
  def recover!(row, account, lifted)
    clock = ended_clock_for(row)

    return unless lifted || clock

    # Lifting is already a one-shot transition (row lock, changed-only true).
    # A clock that ended without a suspension has no such transition behind
    # it, so that half is deduped on the clock it just cleared: re-applying
    # the same Stripe object then says nothing.
    return if !lifted && AccountCounters.increment!(account.id, "dunning:#{clock.to_i}:recovered",
                                                    period: COUNTER_PERIOD) != 1

    BillingMailer.payment_recovered(account, lifted: lifted.present?).deliver_later!
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
  # `proration_date` is the MOMENT the proration is calculated from, and it is
  # pinned rather than left to Stripe's "now". Without it the preview prices
  # the remainder of the period as it stands at one instant and the charge
  # prices it at another, and a renewal falling between the two invoices a
  # whole period the customer never saw. Minted once when the offer is signed
  # (UsersController) and carried through both calls.
  def preview_seat_addition(row, quantity_after: row.quantity + 1, proration_date: Time.current.to_i)
    preview = StripeBilling.client.v1.invoices.create_preview(
      { customer: row.stripe_customer_id,
        subscription: row.stripe_subscription_id,
        subscription_details: {
          items: [{ id: row.stripe_item_id, quantity: quantity_after }],
          proration_behavior: 'always_invoice',
          proration_date:
        } }
    )

    { quantity_after:,
      proration_date:,
      amount_cents: StripeBilling::SubscriptionSync.field(preview, :amount_due).to_i,
      currency: StripeBilling::SubscriptionSync.field(preview, :currency).to_s.presence || 'usd',
      subscription_id: row.stripe_subscription_id,
      item_id: row.stripe_item_id }
  end

  # Money as a person reads it. The one formatter — a refund notice writes it
  # through here too (StripeBilling::Linker::Refund#formatted_amount).
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
  def add_seat!(row, quantity_after:, idempotency_key:, proration_date:)
    StripeBilling.client.v1.subscriptions.update(
      row.stripe_subscription_id,
      { items: [{ id: row.stripe_item_id, quantity: quantity_after }],
        proration_behavior: 'always_invoice',
        # The same instant the customer was quoted from, so the invoice that
        # comes out of this is the one they agreed to.
        proration_date:,
        payment_behavior: 'pending_if_incomplete' },
      { idempotency_key: }
    )
  end

  # Did Stripe park the change instead of making it? Then the seat is not
  # bought, however healthy the answer looked.
  def pending_update?(stripe_subscription)
    StripeBilling::SubscriptionSync.field(stripe_subscription, :pending_update).present?
  end

  # How long Stripe will hold that parked change open. It is the deadline the
  # customer has to finish their card step, and therefore the life of the
  # parked invitation waiting on it (checkpoint 7, B1). Stripe always sends
  # one; the day's grace below is only so a missing field can never write a
  # row with no clock on it at all.
  def pending_update_expires_at(stripe_subscription, default: 1.day.from_now)
    parked = StripeBilling::SubscriptionSync.field(stripe_subscription, :pending_update)
    expires = StripeBilling::SubscriptionSync.field(parked, :expires_at) if parked.present?

    expires.present? ? Time.zone.at(expires.to_i) : default
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
  #
  # Three answers, because the caller has to be able to tell "handed back"
  # from "could not hand back": :updated (Stripe now bills fewer seats),
  # :noop (there was nothing to hand back, or nothing to hand it back to),
  # :failed (Stripe would not take it). Only :failed leaves work to retry.
  def release_seats!(row)
    return :noop unless manageable?(row)
    return :noop if row.stripe_subscription_id.blank? || row.stripe_item_id.blank?
    return :noop unless StripeBilling::Linker.holds_live_subscription?(row)

    changing_seats do
      StripeBilling::Linker.with_account_lock(row) do
        # Inside the lock the row is re-read: a webhook that changed the
        # quantity a moment ago wins, and the target is computed from what is
        # true now rather than from what the sweep saw.
        target = [Accounts.seat_occupancy(row.account), 1].max

        next :noop if target >= row.quantity

        StripeBilling.client.v1.subscriptions.update(
          row.stripe_subscription_id,
          { items: [{ id: row.stripe_item_id, quantity: target }], proration_behavior: 'none' }
        )

        StripeBilling::Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)

        :updated
      end
    end
  rescue Stripe::StripeError, StripeBilling::ListIncomplete, ActiveRecord::LockWaitTimeout => e
    # The seat stays paid for one more cycle, which is a billing annoyance
    # rather than a broken account — as long as somebody asks again. Nothing
    # is marked handled on this path, and the hourly sweep retries.
    ErrorReport.error(e, account_id: row.account_id)

    :failed
  end

  # The backstop under every way a seat count can drift upward and stay
  # there: a parked change Stripe applied later, a release that failed on a
  # Stripe timeout, a member removed while Stripe was unreachable. It decides
  # nothing new — it asks the same question release_seats! answers, for every
  # row that is currently billing for more seats than are occupied. This is
  # also what catches a `pending_update` the customer finished in Stripe's
  # own portal days later: the seat was added, the invitation it would have
  # held was never written, and nothing else would ever ask for it back.
  #
  # A purchase in flight is safe from it without any flag: the buyer holds the
  # account's row lock from the moment Stripe agrees until the invitation that
  # fills the seat is written, and this asks its question inside that same
  # lock — so it can only ever see the finished picture.
  def reconcile_seats!
    reconcilable_rows.find_each do |row|
      next unless manageable?(row)
      next unless StripeBilling::Linker.holds_live_subscription?(row)
      # Counting occupancy is several queries per account, so it is the LAST
      # question asked, never the first.
      next if row.quantity <= Accounts.seat_occupancy(row.account)

      release_seats!(row)
    rescue StandardError => e
      ErrorReport.error(e, account_id: row.account_id)
    end

    nil
  end

  # Rows worth asking about at all: they name a subscription and the item on
  # it, and Stripe has said that subscription is alive. Without this the sweep
  # walked every row the app has ever written every hour, and counted
  # occupancy for accounts whose subscription ended months ago — rows it can
  # never converge, because there is nothing there to change.
  #
  # A BLANK status is not "probably fine": SubscriptionPolicy.live_status?
  # says no to it, and a row in that state is one the nightly reconciliation
  # is there to refresh from Stripe, not one the seat sweep should act on.
  def reconcilable_rows
    AccountSubscription.where.not(stripe_subscription_id: nil)
                       .where.not(stripe_item_id: nil)
                       .where.not(stripe_status: [nil, *StripeBilling::SubscriptionPolicy::DEAD_STRIPE_STATUSES])
  end

  # The other half of the hourly tick: seats that an invitation was holding
  # and no longer is — the invitation lapsed, or an admin cancelled it while
  # Stripe was unreachable.
  #
  # Neither expiry nor revocation needs writing to stop occupying a seat:
  # `pending` already ignores both, so occupancy drops the moment the clock
  # passes or the cancel is saved. What DOES need writing is `released_at`,
  # and only once Stripe has actually taken the lower number — it is a
  # "handled" marker, so writing it on a failure would lose the seat's money
  # for good, and never writing it would ask Stripe to set the same quantity
  # every hour for the rest of the subscription's life.
  def expire_invites!(now: Time.current)
    revoke_closed_login_invites!(now:)

    unreleased_invites(now).distinct.pluck(:account_id).each do |account_id|
      release_invites_for!(account_id, now:)
    rescue StandardError => e
      ErrorReport.error(e, account_id:)
    end

    nil
  end

  # Ask the same live-address verdict as acceptance. collision_user_id is
  # only a historical hint: an address can acquire a holder after the invite.
  # Revocation drops occupancy; the normal release path settles Stripe and
  # writes released_at only after success, preserving retries on failure.
  def revoke_closed_login_invites!(now: Time.current)
    AccountInvite.pending.where(released_at: nil).find_each do |invite|
      Quotas.with_creation_lock(invite.account) do
        invite.with_lock do
          next unless invite.pending? && AccountInvites.verdict_for(invite) == :closed_login

          invite.update!(revoked_at: now)
        end
      end
    rescue StandardError => e
      ErrorReport.error(e, account_id: invite.account_id)
    end
  end

  # Every invitation that has stopped holding its seat and has not been
  # settled with Stripe yet: lapsed ones and cancelled ones alike.
  # A PARKED purchase is deliberately not in here (checkpoint 7, B1): it never
  # took a seat off Stripe, so there is nothing to hand back and asking would
  # be a call about a quantity nobody changed. Those rows are dropped by
  # `discard_parked_invites!` instead, and a parked row that was PROMOTED has
  # no pending marker left on it, so it settles here like any other.
  def unreleased_invites(now = Time.current)
    AccountInvite.where(released_at: nil, accepted_at: nil)
                 .where(payment_pending_until: nil)
                 .where('account_invites.revoked_at IS NOT NULL OR account_invites.expires_at <= ?', now)
  end

  # Parked seat purchases Stripe has given up on (checkpoint 7, B1). The
  # customer never finished the card step, the pending update has expired, and
  # the subscription was never changed — so the row is simply dropped. No
  # Stripe call, no quantity touched, nothing to refund.
  def discard_parked_invites!(now: Time.current)
    AccountInvites.discard_parked!(now:)

    nil
  end

  def release_invites_for!(account_id, now: Time.current)
    account = Account.find_by(id: account_id)

    return if account.nil?

    row = Plans.billing_account(account).account_subscription
    outcome = row ? release_seats!(row) : :noop

    # A Stripe failure leaves released_at nil, and the next tick tries again.
    return if outcome == :failed

    unreleased_invites(now).where(account_id:).update_all(released_at: now)
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

    # The cheap way out, taken before any lock: the overwhelming majority of
    # the events that reach here are about accounts that fit their plan
    # perfectly well, and none of them should pay for a row lock. It is only
    # a fast path — the same question is asked again under the lock, where
    # the answer is the one that counts.
    return if Accounts.seat_occupancy(account) <= seats

    outcome = park_everyone_but_one_admin!(account, seats)

    return if outcome.nil?

    kept, demoted, revoked = outcome

    return if demoted.zero? && revoked.zero?

    # Outside the lock on purpose: the mail is the only step here that talks
    # to anything but our own database.
    BillingMailer.seats_reduced(account, kept: kept.find { |user| user.account_id == account.id } || kept.first,
                                         seats:, revoked:).deliver_later!
  end

  # The whole downgrade decision, taken and written under the ACCOUNT's row
  # lock (review 8, F2). Answers [kept, demoted_count, revoked_count], or nil
  # when the account turned out to fit its plan after all.
  #
  # WHY THE LOCK. Choosing who keeps a seat is a READ, and on its own it
  # promises nothing. With administrators A and B this used to happen:
  #
  #   1. the downgrade reads the account, decides to keep A, and satisfies
  #      itself that B is not the last administrator — because A is still
  #      one;
  #   2. B, on the users page, parks A read-only through the manual door.
  #      That door IS locked (Accounts.with_last_admin_guard) and its check
  #      passes honestly: at that moment B is a full-access administrator, so
  #      A is not the last one;
  #   3. the downgrade, still holding its decision from step 1, parks B.
  #
  # Nobody is left who can invite anyone, change a role, or fix the account's
  # billing — and no unique index or validation stands in the way, because
  # the two writes are to different user rows. The manual doors were brought
  # under the account row lock precisely so they could not do this to each
  # other; the automatic one has to stand in the same queue, or the guard
  # only ever protected half the doors.
  #
  # LOCK ORDER — one order, obeyed by every path that touches seats:
  #
  #     account_subscriptions row  →  accounts rows, ascending id
  #                                →  Quotas advisory lock
  #
  #   * the billing doors (webhooks, the Checkout return, the nightly
  #     reconciliation, the seat purchase) enter through
  #     StripeBilling::Linker.with_account_lock, which holds the SUBSCRIPTION
  #     row, and everything below them — AccountStates.suspend! /
  #     lift_suspension! and now this — takes ACCOUNT rows inside it;
  #   * the manual doors (UsersController#destroy/#update,
  #     UsersReadOnlyController#create) take ONE account row —
  #     Accounts.with_last_admin_guard, the row of the account that could be
  #     stranded — and the Quotas advisory creation lock inside it. They hand
  #     the seat back to Stripe, the only thing that would take the
  #     subscription row, strictly AFTER the account lock is released;
  #   * this path takes SEVERAL account rows, because a downgrade parks
  #     people across the whole seat family (the account and its linked
  #     children), and a manual park in a child locks the CHILD's row rather
  #     than the parent's. Locking only the parent would leave a child
  #     exposed to exactly the race described above. They are taken in
  #     ascending id order, in one statement, which is what keeps two
  #     overlapping families from deadlocking each other.
  #
  # So no path ever holds an account row while it waits for the subscription
  # row, and no two paths take account rows in opposite orders. Nothing
  # inside this block talks to Stripe: revoking a pending invitation has no
  # Stripe call to make (the subscription it would have billed is the one
  # that just ended) and the mail is sent by the caller, outside.
  def park_everyone_but_one_admin!(account, seats)
    with_seat_family_lock(account) do
      # Asked again on the far side of the lock. Whoever else was writing to
      # these accounts has now committed, so this is the first read that is
      # worth acting on — and a family that no longer overflows its plan (a
      # member archived, an invitation cancelled, a seat handed back while we
      # queued) is left alone.
      next nil if Accounts.seat_occupancy(account) <= seats

      kept = admins_to_keep(account)

      [kept, demote_members!(account, kept), revoke_pending_invites!(account)]
    end
  end

  # Every account whose people share these seats, locked together and in
  # ascending id order.
  #
  # One `SELECT ... FOR UPDATE ORDER BY id` rather than a nest of
  # `with_lock`s: it is the same row lock the manual guard takes (that is
  # what makes the two queue behind each other at all), and taking the whole
  # set in one ordered statement is what makes the order impossible to get
  # wrong. A family of one — which is nearly every account — is a single row
  # lock and identical to what `account.with_lock` would have done.
  def with_seat_family_lock(account)
    ids = Accounts.seat_account_ids(account)

    ApplicationRecord.transaction do
      Account.where(id: ids).order(:id).lock.load

      yield
    end
  end

  # Who keeps working: the admin who was here most recently — one per ACTIVE
  # account in the family, not one for the family. Somebody has to be able to
  # administer each account tomorrow, and picking a single winner across a
  # parent and its linked children left a child with nobody who could invite,
  # change a role or fix anything ever again. "Whoever signed in last" is the
  # closest thing to "whoever is running this account" that we can read
  # without asking; a tie (nobody has ever signed in) goes to the oldest row,
  # the person who most likely created it.
  def admins_to_keep(account)
    candidates = Accounts.seat_holders(Accounts.seat_account_ids(account))

    candidates.group_by(&:account_id).filter_map do |_account_id, people|
      people.select(&:admin?).min_by { |user| [-user.current_sign_in_at.to_i, user.id] } ||
        people.min_by(&:id)
    end
  end

  # Only ever called from inside park_everyone_but_one_admin!, i.e. with the
  # account's row lock held: both the read below and the write it decides are
  # inside it, which is what stops the manual doors interleaving between them.
  def demote_members!(account, kept)
    scope = Accounts.seat_holders(Accounts.seat_account_ids(account)).where.not(id: kept.map(&:id))

    # Belt and braces on top of keeping one admin per account: whatever the
    # seat arithmetic says, the last person who can administer an account is
    # never the one it takes the seat from. `Accounts.last_admin?` is the
    # unlocked read — it is trustworthy HERE only because the account row is
    # already locked around it.
    demotable = scope.reject { |user| Accounts.last_admin?(user) }

    return 0 if demotable.empty?

    User.where(id: demotable.map(&:id)).update_all(read_only_at: Time.current)
  end

  # A pending invitation on a plan that no longer has room for it is a seat
  # nobody can take: left alone, accepting it would put a second full-access
  # member into a one-seat account. They are cancelled here rather than left
  # to lapse, and marked released in the same breath — there is no Stripe
  # call to make, because the subscription they would have been billed on is
  # the one that just ended.
  def revoke_pending_invites!(account)
    now = Time.current

    AccountInvite.pending.where(account_id: Accounts.seat_account_ids(account))
                 .update_all(revoked_at: now, released_at: now)
  end
end
