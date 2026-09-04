# frozen_string_literal: true

# The quota engine. Every method takes an Account and resolves the BILLING
# account inside (Plans.billing_account): counts and limits belong to the
# billing account, and a testing or linked child's usage rolls up to its
# parent. Counts are live queries over the real tables — no cached "used"
# number anywhere, so a share link that pauses at the cap resumes by itself
# at month rollover (docs/quotas-and-limits.md).
#
# Free accounts are hard-capped (completions, sends, open documents) on every
# path that creates a document to sign; paid accounts are never blocked by a
# quota (D42) — they get warn-flags for the operator; internal and operator
# accounts are exempt from everything. The one refusal every customer account
# can meet is the sending pause, which is abuse policy (lib/sending_pause.rb),
# not quota.
module Quotas
  # Fixed first argument of the two-int pg_advisory_xact_lock so creation
  # locks never collide with another feature's advisory locks.
  LOCK_NAMESPACE = 52_001

  # Where the upgrade call-to-action sends people (Phase D builds the page).
  USAGE_PATH = '/settings/usage'

  # The snapshot of the durable send counter taken at the instant a paid
  # subscription ended (D43: "counters apply prospectively"). It is written
  # under the CURRENT month's period, so it disappears by itself at rollover
  # and can never make an older month's numbers wrong.
  DOWNGRADE_SENDS_OFFSET_KEY = 'submissions_created:downgrade_offset'

  # The instant that snapshot was taken, as a Unix time, under the same
  # month's period (checkpoint 7, P4/P7). ONE instant has to anchor BOTH
  # halves of a prospective month, or the two disagree whenever a downgrade
  # is applied late: Stripe's `ended_at` can be hours older than the moment
  # the app found out (a lost webhook the nightly reconciliation picks up),
  # and counting completions from Stripe's clock while counting sends from
  # ours forgave a day of sends and charged the same day's completions.
  #
  # The instant chosen is when the transition was APPLIED, and the rule it
  # encodes is the customer-friendly one: everything the account did before
  # the app knew it had stopped paying was done on the paid plan, and stays
  # charged to the paid plan. It cannot be gamed the other way either — the
  # window can only ever be SHORTER than "since Stripe cancelled", never
  # longer, so a late apply never hands anybody extra free allowance.
  DOWNGRADE_AT_KEY = 'downgrade_applied_at'

  LimitSet = Struct.new(:completions_per_month, :sends_per_month, :in_flight, :seats, :storage_bytes)

  class LimitReached < StandardError
    REASONS = %i[completions sends in_flight sending_paused suspended].freeze

    attr_reader :reason, :limit, :resets_at

    def initialize(reason, limit: nil, resets_at: nil)
      @reason = reason
      @limit = limit
      @resets_at = resets_at

      super(Quotas.message_for(reason, limit:, resets_at:, locale: :en))
    end

    # The same explanation in the locale of whoever is looking at it.
    def localized_message
      Quotas.message_for(reason, limit:, resets_at:)
    end
  end

  class SeatLimitReached < StandardError
    attr_reader :seats, :plan

    def initialize(seats, plan:)
      @seats = seats
      @plan = plan

      super(Quotas.seat_message_for(seats, plan:, locale: :en))
    end

    def localized_message
      Quotas.seat_message_for(seats, plan:)
    end
  end

  module_function

  # The billing account plus every child whose usage rolls up to it.
  def account_ids(account)
    billing = Plans.billing_account(account)

    [billing.id, *AccountLinkedAccount.where(account_id: billing.id).pluck(:linked_account_id)]
  end

  # Plan defaults with the operator's per-account override winning field by
  # field. nil means unlimited. An internal or operator account has no caps
  # to override: a stray override row on one is ignored.
  def limits_for(account)
    billing = Plans.billing_account(account)
    defaults = default_limits_for(billing)

    return defaults if Plans.key_for(billing) == Plans::INTERNAL

    override = billing.limit_override

    return defaults unless override

    LimitSet.new(**defaults.to_h, **override.slice(AccountLimitOverride::FIELDS).compact.symbolize_keys)
  end

  def default_limits_for(billing)
    case Plans.key_for(billing)
    when Plans::FREE
      LimitSet.new(completions_per_month: Limits::FREE_COMPLETIONS_PER_MONTH,
                   sends_per_month: Limits::FREE_SENDS_PER_MONTH,
                   in_flight: Limits::FREE_IN_FLIGHT,
                   seats: Limits::FREE_SEATS,
                   storage_bytes: Limits::FREE_STORAGE_BYTES)
    when Plans::PAID
      seats = billing.account_subscription.quantity

      LimitSet.new(seats:, storage_bytes: Limits::PAID_STORAGE_BYTES_PER_SEAT * seats)
    else
      LimitSet.new
    end
  end

  # UTC calendar month — or, on a free account whose paid subscription ended
  # part-way through this month, the shorter window that starts where the
  # paid plan stopped (see period_start).
  def month_range(account = nil)
    period_start(account)..
  end

  def resets_at(_account = nil)
    Time.current.utc.beginning_of_month.next_month
  end

  # Where THIS account's current free month begins.
  #
  # Normally the 1st, UTC. But D43 says a downgrade's counters "apply
  # prospectively": a customer who used the paid plan hard and then cancelled
  # on the 3rd starts their free month at the cancellation, not on the 1st —
  # otherwise the free caps would be measured against usage that was paid
  # for, and docs/billing.md's promise that a lapsed customer "can write
  # again" would be false until the 1st. Only ever moves the start FORWARD
  # inside the current month, and only on the free plan, so nothing else in
  # the app sees a different month.
  def period_start(account = nil)
    month_start = Time.current.utc.beginning_of_month

    return month_start if account.nil?

    billing = Plans.billing_account(account)

    return month_start unless Plans.key_for(billing) == Plans::FREE

    started_at = downgrade_at(billing) || billing.account_subscription&.ended_at

    return month_start if started_at.blank? || started_at <= month_start

    started_at
  end

  # When the paid → free transition was APPLIED, if it was applied this month.
  # The send snapshot beside it was taken at this same instant, which is the
  # whole point: completions and sends measure the same window (P4/P7).
  #
  # `ended_at` is only the fallback, for a row stamped by a path that recorded
  # no snapshot — an account downgraded before this existed, or one whose
  # counter row was removed. Stripe's clock is the second-best answer to
  # "when did this account stop paying", not the first.
  def downgrade_at(billing)
    seconds = AccountCounters.value(billing.id, DOWNGRADE_AT_KEY)

    seconds.positive? ? Time.zone.at(seconds) : nil
  end

  # Documents completed this month: a document counts the first time ANY of
  # its signers completes it (is_first, D41) — later signers, corrections and
  # resubmits never add.
  def completions_this_month(account)
    billing = Plans.billing_account(account)

    CompletedSubmitter.where(account_id: account_ids(billing), is_first: true,
                             completed_at: month_range(billing)).count
  end

  # Documents sent this month: every submission created on any path, selfsign
  # included (D58); deleting a submission never gives the send back.
  #
  # The counter itself is append-only and is never rewritten — a downgrade
  # subtracts the snapshot taken when the paid plan ended (D43, prospective
  # counters), which leaves "deletion never resets a send" exactly as true as
  # it was.
  def sends_this_month(account)
    billing = Plans.billing_account(account)
    counted = account_ids(billing).sum { |id| AccountCounters.value(id, 'submissions_created') }

    [counted - downgrade_sends_offset(billing), 0].max
  end

  # How many of this month's sends were spent while the account was still
  # paying. Zero unless the paid plan ended this month AND the account is on
  # the free plan now: a paid account is never blocked by a send cap, and the
  # snapshot's month period makes it vanish at rollover.
  def downgrade_sends_offset(billing)
    return 0 unless Plans.key_for(billing) == Plans::FREE

    AccountCounters.value(billing.id, DOWNGRADE_SENDS_OFFSET_KEY)
  end

  # Called by StripeBilling::SubscriptionSync at a paid → free transition,
  # inside the transaction that writes the subscription row. Records where
  # the send counter stood so the free month that starts here counts only
  # what is sent from now on. Overwrites a snapshot from earlier in the same
  # month: the LAST downgrade is the one the free month starts at.
  def record_downgrade!(account)
    billing = Plans.billing_account(account)
    counted = account_ids(billing).sum { |id| AccountCounters.value(id, 'submissions_created') }
    # ONE instant, read once, written beside the snapshot it belongs to: the
    # completions window and the sends window are the same window (P4/P7).
    at = Time.current
    period = AccountCounters.month_period(at)

    AccountCounters.set!(billing.id, DOWNGRADE_SENDS_OFFSET_KEY, counted, period:)
    AccountCounters.set!(billing.id, DOWNGRADE_AT_KEY, at.to_i, period:)

    counted
  end

  def sends_today(account)
    account_ids(account).sum do |id|
      AccountCounters.value(id, 'submissions_created', period: AccountCounters.day_period)
    end
  end

  # Documents waiting for signatures: not archived, not expired, still has a
  # signer who neither completed nor declined, nobody declined, and the
  # template (when there is one) is not archived.
  def in_flight(account)
    in_flight_scope(account_ids(account)).count
  end

  def in_flight_scope(ids)
    submitters = Submitter.arel_table
    submissions = Submission.arel_table
    same_submission = submitters[:submission_id].eq(submissions[:id])
    pending = Submitter.where(same_submission).where(completed_at: nil, declined_at: nil)
    declined = Submitter.where(same_submission).where.not(declined_at: nil)

    Submission.where(account_id: ids, archived_at: nil)
              .where(submissions[:expire_at].eq(nil).or(submissions[:expire_at].gt(Time.current)))
              .where(pending.select(1).arel.exists)
              .where.not(declined.select(1).arel.exists)
              .left_joins(:template)
              .where(templates: { archived_at: nil })
  end

  # The one check every creation path makes, inside with_creation_lock.
  # `count` is how many submissions the caller is about to create: a batch is
  # refused whole when it would cross a cap.
  #
  # `correction_of` is the ORIGIN document when this creation is a correction
  # being re-sent (D74). A correction of a family that has already been
  # counted cannot add a completion, so the monthly completions cap is not
  # what should stand in its way — every other rule still does.
  def assert_can_create_submissions!(account, count: 1, correction_of: nil)
    billing = Plans.billing_account(account)
    plan = Plans.key_for(billing)

    return true if plan == Plans::INTERNAL

    raise LimitReached, :sending_paused if SendingPause.paused?(billing)

    # A suspended account creates nothing, on any plan and through any door.
    # The Ability layer already closes the HTML controllers and the token
    # guard closes the API; this is the chokepoint everything else shares —
    # share links, the start form, MCP, bulk sends — so a path added later
    # cannot forget it. Never INTERNAL: the early return above is above this.
    raise LimitReached, :suspended if AccountStates.read_only?(account)

    return true unless plan == Plans::FREE

    limits = limits_for(billing)

    if !counted_family?(correction_of) && limits.completions_per_month &&
       completions_this_month(billing) >= limits.completions_per_month
      raise LimitReached.new(:completions, limit: limits.completions_per_month, resets_at: resets_at)
    end

    if limits.sends_per_month && sends_this_month(billing) + count > limits.sends_per_month
      raise LimitReached.new(:sends, limit: limits.sends_per_month, resets_at: resets_at)
    end

    if limits.in_flight && in_flight(billing) + count > limits.in_flight
      raise LimitReached.new(:in_flight, limit: limits.in_flight, resets_at: resets_at)
    end

    true
  end

  # D74: is this creation a correction of a document whose family has already
  # been counted? Only then is the completions cap skipped — a correction of
  # a family that never completed is an ordinary new document to sign, and a
  # free account at its cap is refused it like any other.
  def counted_family?(correction_of)
    correction_of.present? && Submissions::Lineage.first_completion_exists?(correction_of)
  end

  # The reason a share link is closed right now, or nil. Computed on every
  # call — there is no persisted flag to go stale.
  def share_link_paused?(account)
    assert_can_create_submissions!(account)

    nil
  rescue LimitReached => e
    e.reason
  end

  # Serialises every creator on one billing account: the check and the
  # creation happen inside, so two concurrent creators cannot both read
  # "14 of 15" and both create. A transaction-scoped advisory lock, so it
  # works inside a spec's wrapping transaction (savepoint) too.
  def with_creation_lock(account)
    billing = Plans.billing_account(account)

    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{billing.id.to_i})"
      )

      yield
    end
  end

  # Called by ProcessSubmitterCompletionJob right after it records a
  # first-signer completion.
  def after_first_completion(account)
    billing = Plans.billing_account(account)

    case Plans.key_for(billing)
    when Plans::FREE then free_completion_warning(billing)
    when Plans::PAID then paid_completion_signals(billing)
    end

    nil
  end

  # One warning email per month from the second-to-last completion on (4 of 5
  # on the default cap). The durable counter is the once-per-month guard, so
  # ">=" cannot double-send; it only stops a missed completion (two signers
  # finishing at once) from skipping the warning altogether.
  def free_completion_warning(billing)
    limit = limits_for(billing).completions_per_month

    return if limit.nil?

    warning_at = limit - (Limits::FREE_COMPLETIONS_PER_MONTH - Limits::FREE_COMPLETIONS_WARNING_AT)

    return unless completions_this_month(billing) >= warning_at
    return unless AccountCounters.increment!(billing.id, 'quota_mail:completions_warning') == 1

    QuotaMailer.completions_warning(billing).deliver_later!
  end

  # Fair use for a paid account: an email at 80% of 500 × seats, a review
  # flag at 100%. Neither blocks anything.
  def paid_completion_signals(billing)
    seats = limits_for(billing).seats || 1
    threshold = Limits::PAID_COMPLETIONS_REVIEW_PER_SEAT * seats
    used = completions_this_month(billing)

    if used >= (threshold * Limits::WARNING_FRACTION).ceil &&
       AccountCounters.increment!(billing.id, 'quota_mail:paid_usage_warning') == 1
      QuotaMailer.paid_usage_warning(billing).deliver_later!
    end

    return if used < threshold

    AbuseFlags.record!(billing, 'fair_use_review', period: AccountCounters.month_period,
                                                   details: { completions: used, threshold: })
  end

  # Called after a successful creation on a paid account, inside the lock.
  # Warn-flags only: never raises, never blocks.
  def record_paid_signals(account)
    billing = Plans.billing_account(account)

    return unless Plans.key_for(billing) == Plans::PAID

    seats = limits_for(billing).seats || 1
    day = AccountCounters.day_period

    if (sends = sends_today(billing)) > Limits::PAID_SENDS_PER_DAY_PER_SEAT * seats
      AbuseFlags.record!(billing, 'send_velocity', period: day, details: { sends_today: sends, seats: })
    end

    if (open = in_flight(billing)) > Limits::PAID_IN_FLIGHT_PER_SEAT * seats
      AbuseFlags.record!(billing, 'in_flight', period: day, details: { in_flight: open, seats: })
    end

    nil
  rescue StandardError => e
    ErrorReport.error(e, account_id: account.id)

    nil
  end

  # The owner learns a signer was turned away: once per (month, reason). The
  # guard counter is read before it is written, so every visit to a paused
  # link after the first is read-only.
  def notify_share_link_pause!(account, reason)
    billing = Plans.billing_account(account)
    key = "quota_mail:share_link_paused:#{reason}"

    return if AccountCounters.value(billing.id, key) >= 1
    return unless AccountCounters.increment!(billing.id, key) == 1

    QuotaMailer.share_link_paused(billing, reason.to_s).deliver_later!
  end

  def assert_seat_available!(account)
    billing = Plans.billing_account(account)

    return true if Plans.key_for(billing) == Plans::INTERNAL

    seats = limits_for(billing).seats

    return true if seats.nil?
    return true if Accounts.users_count(billing) < seats

    raise SeatLimitReached.new(seats, plan: Plans.key_for(billing))
  end

  # The explanation for a share-link pause reason, in the current locale.
  def pause_message(account, reason)
    limits = limits_for(account)
    limit = { completions: limits.completions_per_month, sends: limits.sends_per_month,
              in_flight: limits.in_flight }[reason.to_sym]

    message_for(reason.to_sym, limit:, resets_at: resets_at)
  end

  def message_for(reason, limit: nil, resets_at: nil, locale: nil)
    I18n.with_locale(locale || I18n.locale) do
      case reason
      when :sending_paused then I18n.t('sending_paused_alert')
      # Not a quota at all: the account is suspended, and the only thing that
      # reopens it is settling the payment.
      when :suspended then I18n.t('account_suspended_alert')
      else I18n.t("quota_reached_#{reason}", limit:, date: resets_at&.utc&.strftime('%Y-%m-%d'))
      end
    end
  end

  def seat_message_for(seats, plan:, locale: nil)
    I18n.with_locale(locale || I18n.locale) do
      plan == Plans::PAID ? I18n.t('seat_limit_paid', count: seats) : I18n.t('seat_limit_free')
    end
  end
end
