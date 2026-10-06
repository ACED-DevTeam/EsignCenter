# frozen_string_literal: true

# Fired every minute by sidekiq-cron (config/schedule.yml). Its only purpose is
# evidence that the scheduler is alive: /up reports the last tick time.
class SchedulerHeartbeatJob < ApplicationJob
  LAST_TICK_KEY = 'esigncenter:scheduler:last_tick_at'

  queue_as :recurrent

  def perform
    Sidekiq.redis { |conn| conn.call('SET', LAST_TICK_KEY, Time.current.iso8601) }
  end
end
