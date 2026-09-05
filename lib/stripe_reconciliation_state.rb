# frozen_string_literal: true

# What the nightly Stripe sweep leaves behind for a person to read: the last
# report it produced, and — when it ran out of its wall-clock budget — the id
# it stopped at so the next night can carry on from there.
#
# Redis rather than a database row, and deliberately: this is operational
# evidence of the last run, not a setting. It is rewritten every night, it is
# worthless the moment a newer run replaces it, and losing it to a Redis flush
# costs nothing but a day's visibility. It also carries Stripe customer and
# subscription ids for accounts all over the platform, which is not something
# to write into the per-account config table the isolation gate watches. It
# lives next to the scheduler stamps (SchedulerStamps) because it is the same
# kind of fact about the same job.
#
# Every write is best effort. A Redis outage must never replace the sweep's
# own error or stop it doing the billing work it exists for; a missing report
# is itself visible evidence on the console's billing tab.
module StripeReconciliationState
  REPORT_KEY = 'esigncenter:stripe:last_reconciliation'
  CURSOR_KEY = 'esigncenter:stripe:sweep_cursor'

  # A report is a picture of one night. Keeping it for a week is long enough
  # for somebody back from a weekend to see what happened and short enough
  # that a stale one cannot be mistaken for last night's.
  REPORT_TTL = 7.days

  module_function

  # `report` is the job's Report struct; `ran_at` is when the run finished.
  def record_report!(report, ran_at: Time.current)
    write(REPORT_KEY, report.to_h.merge(ran_at: ran_at.iso8601).to_json, ttl: REPORT_TTL.to_i)
  end

  # The last report as a plain string-keyed hash, or nil when there is none
  # (never run, expired, or Redis is unreachable).
  def last_report
    parsed = JSON.parse(read(REPORT_KEY).to_s)

    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  # The id the last sweep stopped at, or nil when the last sweep finished.
  # Rows are walked in id order, so "carry on after this id" is the whole of
  # the resume.
  def cursor
    read(CURSOR_KEY).to_s.presence&.to_i
  end

  def cursor=(value)
    value.nil? ? delete(CURSOR_KEY) : write(CURSOR_KEY, value.to_s)
  end

  def read(key)
    Sidekiq.redis { |conn| conn.call('GET', key) }
  rescue StandardError => e
    ErrorReport.error(e)

    nil
  end

  def write(key, value, ttl: nil)
    Sidekiq.redis do |conn|
      ttl ? conn.call('SET', key, value, 'EX', ttl) : conn.call('SET', key, value)
    end
  rescue StandardError => e
    ErrorReport.error(e)

    nil
  end

  def delete(key)
    Sidekiq.redis { |conn| conn.call('DEL', key) }
  rescue StandardError => e
    ErrorReport.error(e)

    nil
  end
end
