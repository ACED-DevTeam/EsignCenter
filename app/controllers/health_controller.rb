# frozen_string_literal: true

# GET /up — the load-balancer / uptime probe. Deliberately not an
# ApplicationController: no session, no authentication, no CSRF, no PII.
# 200 when the database and Redis both answer, 503 otherwise. The scheduler
# heartbeat is reported for humans and dashboards but never flips the status.
class HealthController < ActionController::API
  def show
    db = check { ActiveRecord::Base.lease_connection.select_value('SELECT 1') == 1 }
    redis = check { Sidekiq.redis { |conn| conn.call('PING') } == 'PONG' }
    healthy = db == 'ok' && redis == 'ok'

    render json: {
      status: healthy ? 'ok' : 'degraded',
      db:,
      redis:,
      scheduler_last_tick_at: scheduler_last_tick_at
    }, status: healthy ? :ok : :service_unavailable
  end

  private

  def check
    yield ? 'ok' : 'error'
  rescue StandardError
    'error'
  end

  def scheduler_last_tick_at
    Sidekiq.redis { |conn| conn.call('GET', SchedulerHeartbeatJob::LAST_TICK_KEY) }
  rescue StandardError
    nil
  end
end
