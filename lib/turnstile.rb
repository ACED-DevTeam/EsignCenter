# frozen_string_literal: true

# Cloudflare Turnstile server-side verification for the sign-up form. The
# browser widget hands the form a one-time token; only Cloudflare can say
# whether it is genuine, so this asks — and treats every doubt as a "no": a
# blank token, a missing secret, a network error, a malformed answer all fail
# closed. There is no environment bypass: the test suite stubs the HTTP call
# (spec/support/turnstile_helpers.rb).
module Turnstile
  VERIFY_URL = 'https://challenges.cloudflare.com/turnstile/v0/siteverify'
  TIMEOUT_SECONDS = 5

  VerificationFailed = Class.new(StandardError)

  module_function

  def enabled?
    ENV['TURNSTILE_SECRET_KEY'].present?
  end

  # Whether a page may DRAW the widget: the site key alone, because that is all
  # the browser needs. A widget with an empty site key throws in the browser,
  # so a page without one renders neither the widget nor Cloudflare's script,
  # and its security policy is not widened for a script it will not load.
  def widget?
    ENV['TURNSTILE_SITE_KEY'].present?
  end

  # Whether a form may ENFORCE the check: BOTH keys. The browser needs the site
  # key to draw the widget and the server needs the secret to check its answer;
  # enforcing with only the secret would refuse everybody, because there was no
  # widget to produce a token.
  def configured?
    enabled? && widget?
  end

  def verify!(token, remote_ip)
    raise VerificationFailed, 'missing-input-response' if token.blank?
    raise VerificationFailed, 'turnstile-not-configured' unless enabled?

    body = JSON.parse(request_verification(token, remote_ip).body.to_s)

    raise VerificationFailed, 'malformed-response' unless body.is_a?(Hash)
    return true if body['success'] == true

    raise VerificationFailed, Array(body['error-codes']).join(',').presence || 'not-verified'
  rescue Faraday::Error, JSON::ParserError => e
    ErrorReport.warning(e, remote_ip:)

    raise VerificationFailed, 'verification-unavailable'
  end

  def request_verification(token, remote_ip)
    connection = Faraday.new(request: { timeout: TIMEOUT_SECONDS, open_timeout: TIMEOUT_SECONDS })

    connection.post(VERIFY_URL, secret: ENV.fetch('TURNSTILE_SECRET_KEY'), response: token, remoteip: remote_ip)
  end
end
