# frozen_string_literal: true

# Boot-time check for the sign-up switch. With REGISTRATION_ENABLED=true a
# production deployment must carry the Turnstile keys: without them the
# sign-up form would render no widget and every submission would fail closed,
# so the product would be open and broken at once — refuse to boot instead.
# The sign-in providers are optional (their buttons simply hide): a missing or
# half-filled set is logged and reported, never fatal.
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

    warn_about(GOOGLE_KEYS.select { |key| ENV[key].blank? }, 'Google')

    # Apple has a fourth failure mode Google does not: a slot that is present
    # but still carries the env file's PASTE_ marker, or an id or a key of the
    # wrong shape. Registrations.apple_configured? is the same question the
    # button asks, so the warning and the hidden button can never disagree.
    warn_about(Registrations.apple_configured? ? [] : Registrations::APPLE_KEYS, 'Apple')
  end

  def warn_about(keys, provider)
    return if keys.empty?

    message = "#{keys.join(', ')} is not set; the #{provider} sign-in button is hidden"

    Rails.logger.warn(message)
    ErrorReport.warning(message)
  end
end
