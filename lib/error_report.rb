# frozen_string_literal: true

# The ONE way application code reports a problem. Routes to Sentry when it is
# initialised (SENTRY_DSN set, see config/initializers/sentry.rb) and to the
# Rails log otherwise. Extra keyword arguments become Sentry "extra" context.
# Reporting must never take the caller down, so nothing here raises.
module ErrorReport
  LOGGER_METHODS = { error: :error, warning: :warn, info: :info }.freeze

  module_function

  def error(subject, **context)
    report(:error, subject, context)
  end

  def warning(subject, **context)
    report(:warning, subject, context)
  end

  def info(subject, **context)
    report(:info, subject, context)
  end

  def report(level, subject, context)
    if sentry?
      capture(level, subject, context)
    else
      log(level, subject, context)
    end

    nil
  rescue StandardError => e
    Rails.logger.error("ErrorReport failed: #{e.class}: #{e.message}")

    nil
  end

  def sentry?
    defined?(Sentry) && Sentry.initialized?
  end

  def capture(level, subject, context)
    if subject.is_a?(Exception)
      Sentry.capture_exception(subject, level:, extra: context)
    else
      Sentry.capture_message(subject.to_s, level:, extra: context)
    end
  end

  def log(level, subject, context)
    message = subject.is_a?(Exception) ? "#{subject.class}: #{subject.message}" : subject.to_s
    message = "#{message} #{context.to_json}" if context.present?

    Rails.logger.public_send(LOGGER_METHODS.fetch(level), message)
  end
end
