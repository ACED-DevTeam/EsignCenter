# frozen_string_literal: true

# Boot-time check for the sign-up switch. With REGISTRATION_ENABLED=true a
# production deployment must carry the Turnstile keys: without them the
# sign-up form would render no widget and every submission would fail closed,
# so the product would be open and broken at once — refuse to boot instead.
# Google credentials are optional (the Google button simply hides): missing
# ones are logged and reported, never fatal.
module RegistrationConfigGuard
  TURNSTILE_KEYS = %w[TURNSTILE_SITE_KEY TURNSTILE_SECRET_KEY].freeze
  GOOGLE_KEYS = %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET].freeze

  module_function

  def check!
    return unless Rails.env.production?
    return unless Docuseal.registration_enabled?

    missing_turnstile = TURNSTILE_KEYS.select { |key| ENV[key].blank? }

    if missing_turnstile.any?
      raise "REGISTRATION_ENABLED=true but #{missing_turnstile.join(', ')} " \
            'is not set; sign-up cannot verify visitors without Turnstile'
    end

    missing_google = GOOGLE_KEYS.select { |key| ENV[key].blank? }

    return if missing_google.empty?

    message = "#{missing_google.join(', ')} is not set; the Google sign-in button is hidden"

    Rails.logger.warn(message)
    ErrorReport.warning(message)
  end
end
