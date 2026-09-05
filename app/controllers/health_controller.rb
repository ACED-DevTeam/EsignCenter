# frozen_string_literal: true

# GET /up — the load-balancer / uptime probe. Deliberately not an
# ApplicationController: no session, no authentication, no CSRF, no PII.
# 200 when the database and Redis both answer, 503 otherwise. The scheduler
# heartbeat and the operator account are reported for humans and dashboards
# but never flip the status.
class HealthController < ActionController::API
  def show
    db = check { ActiveRecord::Base.lease_connection.select_value('SELECT 1') == 1 }
    redis = check { Sidekiq.redis { |conn| conn.call('PING') } == 'PONG' }
    healthy = db == 'ok' && redis == 'ok'

    render json: {
      status: healthy ? 'ok' : 'degraded',
      db:,
      redis:,
      scheduler_last_tick_at: scheduler_last_tick_at,
      operator_account: operator_account_state
    }, status: healthy ? :ok : :service_unavailable
  end

  private

  # Has `rake operator:seed` run yet?
  #
  # It matters because the platform signing identity lives on that account: a
  # deploy that takes signing traffic before the seed produces completions
  # with no certificate-backed artefacts behind them, which is a mess to
  # unpick afterwards. So this is the line to read before pointing customers
  # at a fresh instance (docs/render-deploy-checklist.md).
  #
  # Deliberately NOT part of `status`: the seed is a rake task run INSIDE a
  # booted instance, so an instance that refused to come up healthy until the
  # seed existed could never be seeded. "missing" is a to-do, not an outage.
  def operator_account_state
    OperatorConfigs.account.present? ? 'ok' : 'missing'
  rescue StandardError
    'missing'
  end

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
