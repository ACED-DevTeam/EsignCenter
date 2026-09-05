# frozen_string_literal: true

# Evidence of a job's latest attempt, separate from the scheduler heartbeat.
module SchedulerStamps
  JOB_NAMES = %w[stripe_reconciliation billing_lifecycle account_retention comp_expiry].freeze
  KEY_PREFIX = 'esigncenter:scheduler:last_run:'

  module_function

  def record!(job_name)
    started_at = Time.current
    started_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stamp = { started_at: started_at.iso8601, finished_at: nil, duration_ms: nil, outcome: nil, error: nil }
    write(job_name, stamp)

    begin
      result = yield
      stamp[:outcome] = 'ok'

      result
    rescue StandardError => e
      stamp[:outcome] = 'error'
      stamp[:error] = "#{e.class}: #{e.message}".first(500)

      raise
    ensure
      stamp[:finished_at] = Time.current.iso8601
      stamp[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_clock) * 1000).round
      write(job_name, stamp)
    end
  end

  # A Redis outage must not replace a job's original error or prevent the
  # business work. A missing/stale stamp is itself visible firing evidence.
  def write(job_name, stamp)
    Sidekiq.redis { |conn| conn.call('SET', "#{KEY_PREFIX}#{job_name}", stamp.to_json) }
  rescue StandardError => e
    ErrorReport.error(e)
  end

  # An empty hash means the stamp store could not be read at all — Redis is
  # the one dependency this evidence lives in, and the moment an operator
  # reaches for the scheduler tab is exactly the moment Redis is most likely
  # to be the thing that is broken. A normal read always answers with every
  # job name present (its stamp, or nil), so "{}" is unambiguous and the
  # console can say "unavailable" rather than "never run".
  def all
    Sidekiq.redis do |conn|
      stamps = JOB_NAMES.index_with do |name|
        value = conn.call('GET', "#{KEY_PREFIX}#{name}")

        JSON.parse(value) if value
      end
      tick = conn.call('GET', SchedulerHeartbeatJob::LAST_TICK_KEY)
      stamps['scheduler_heartbeat'] = if tick
                                        { 'started_at' => tick, 'finished_at' => tick, 'duration_ms' => 0,
                                          'outcome' => 'ok', 'error' => nil }
                                      end

      stamps
    end
  rescue StandardError => e
    ErrorReport.error(e)

    {}
  end
end
