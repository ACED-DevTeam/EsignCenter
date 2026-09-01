# frozen_string_literal: true

module AccountCounters
  module_function

  def month_period(time = Time.current)
    time.utc.strftime('%Y-%m')
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

  def value(account_id, key, period: month_period)
    AccountCounter.find_by(account_id:, key:, period:)&.value || 0
  end
end
