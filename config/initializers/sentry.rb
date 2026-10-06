# frozen_string_literal: true

require_relative '../../lib/docuseal'

# Error reporting (D64). Initialised only when a DSN is
# configured; without one ErrorReport falls back to the Rails log.
if ENV['SENTRY_DSN'].present?
  Sentry.init do |config|
    config.dsn = ENV.fetch('SENTRY_DSN')
    config.environment = ENV.fetch('SENTRY_ENVIRONMENT', Rails.env)
    config.release = Docuseal.version.presence
    config.send_default_pii = false
    config.breadcrumbs_logger = [:active_support_logger]
    # Anything reported through Rails.error (Rails' own error reporter, used
    # by framework internals) is forwarded to Sentry as well; application
    # code reports through ErrorReport.
    config.rails.register_error_subscriber = true
    # Errors only: no performance tracing.
    config.traces_sample_rate = 0.0
  end
end
