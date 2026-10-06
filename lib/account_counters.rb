# frozen_string_literal: true

module AccountCounters
  module_function

  def month_period(time = Time.current)
    time.utc.strftime('%Y-%m')
  end

  # UTC calendar day, for the per-day velocity signals (Quotas.record_paid_signals).
  def day_period(time = Time.current)
    time.utc.strftime('%Y-%m-%d')
  end

  def increment!(account_id, key, period: month_period, by: 1)
    result = AccountCounter.upsert(
      { account_id:, key:, period:, value: by },
      unique_by: %i[account_id key period],
      on_duplicate: Arel.sql('value = account_counters.value + EXCLUDED.value, updated_at = CURRENT_TIMESTAMP'),
      returning: [:value]
    )

    result.rows.first.first
  end

  # A counter that is a SNAPSHOT rather than a tally: the new value replaces
  # whatever was there instead of being added to it. Used for the downgrade
  # send offset (Quotas::DOWNGRADE_SENDS_OFFSET_KEY), where a second
  # downgrade in the same month must move the mark forward, not double it.
  def set!(account_id, key, value, period: month_period)
    result = AccountCounter.upsert(
      { account_id:, key:, period:, value: },
      unique_by: %i[account_id key period],
      on_duplicate: Arel.sql('value = EXCLUDED.value, updated_at = CURRENT_TIMESTAMP'),
      returning: [:value]
    )

    result.rows.first.first
  end

  def value(account_id, key, period: month_period)
    AccountCounter.find_by(account_id:, key:, period:)&.value || 0
  end
end
