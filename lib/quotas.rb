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

  LimitSet = Struct.new(:completions_per_month, :sends_per_month, :in_flight, :seats, :storage_bytes)

  class LimitReached < StandardError
    REASONS = %i[completions sends in_flight sending_paused].freeze

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

  # UTC calendar month.
  def month_range
    Time.current.utc.beginning_of_month..
  end

  def resets_at(_account = nil)
    Time.current.utc.beginning_of_month.next_month
  end

  # Documents completed this month: a document counts the first time ANY of
  # its signers completes it (is_first, D41) — later signers, corrections and
  # resubmits never add.
  def completions_this_month(account)
    CompletedSubmitter.where(account_id: account_ids(account), is_first: true, completed_at: month_range).count
  end

  # Documents sent this month: every submission created on any path, selfsign
  # included (D58); deleting a submission never gives the send back.
  def sends_this_month(account)
    account_ids(account).sum { |id| AccountCounters.value(id, 'submissions_created') }
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
  def assert_can_create_submissions!(account, count: 1)
    billing = Plans.billing_account(account)
    plan = Plans.key_for(billing)

    return true if plan == Plans::INTERNAL

    raise LimitReached, :sending_paused if SendingPause.paused?(billing)

    return true unless plan == Plans::FREE

    limits = limits_for(billing)

    if limits.completions_per_month && completions_this_month(billing) >= limits.completions_per_month
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
      if reason == :sending_paused
        I18n.t('sending_paused_alert')
      else
        I18n.t("quota_reached_#{reason}", limit:, date: resets_at&.utc&.strftime('%Y-%m-%d'))
      end
    end
  end

  def seat_message_for(seats, plan:, locale: nil)
    I18n.with_locale(locale || I18n.locale) do
      plan == Plans::PAID ? I18n.t('seat_limit_paid', count: seats) : I18n.t('seat_limit_free')
    end
  end
end
