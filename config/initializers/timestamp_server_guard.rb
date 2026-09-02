# frozen_string_literal: true

# Timestamps are part of what a signed document promises: a signature carries a
# time attested by an RFC 3161 authority, never one generated locally. With no
# TIMESERVER_URL a production deployment would sign without that attestation,
# so production refuses to boot; other environments only warn (the test suite
# signs without a TSA on purpose).
module TimestampServerGuard
  module_function

  def check!
    return if ENV['TIMESERVER_URL'].present?

    message = 'TIMESERVER_URL is not set; signatures would carry no trusted timestamp'

    raise message if Rails.env.production?

    Rails.logger.warn(message) unless Rails.env.test?
  end
end

TimestampServerGuard.check!
