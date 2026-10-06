# frozen_string_literal: true

module RateLimit
  LimitApproached = Class.new(StandardError)

  module_function

  def store
    @store ||=
      if Rails.env.test?
        ActiveSupport::Cache::MemoryStore.new
      else
        ActiveSupport::Cache::RedisCacheStore.new(
          url: ENV.fetch('REDIS_URL'),
          namespace: 'rate_limit',
          error_handler: method(:report_store_error)
        )
      end
  end

  # An unreachable Redis fails open (the store returns nil and every limit is
  # off until it is back); the failure itself goes through the one reporting
  # seam so it reaches Sentry and the log. Never raises.
  def report_store_error(method:, returning:, exception:)
    ErrorReport.warning(exception, method:, returning:)
  end

  def call(key, limit:, ttl:, enabled: true)
    return true unless enabled

    value = store.increment(key, 1, expires_in: ttl)

    raise LimitApproached if value && value > limit

    true
  end
end
