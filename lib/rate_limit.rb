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
          error_handler: lambda do |method:, returning:, exception:|
            Rails.error.report(exception, handled: true, severity: :warning, context: { method:, returning: })
          end
        )
      end
  end

  def call(key, limit:, ttl:, enabled: true)
    return true unless enabled

    value = store.increment(key, 1, expires_in: ttl)

    raise LimitApproached if value && value > limit

    true
  end
end
