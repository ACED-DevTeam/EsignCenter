# frozen_string_literal: true

# Sign in with Apple comes back as a cross-site POST, and a cross-site POST
# arrives without the session cookie unless we say otherwise.
#
# Apple's response mode for a sign-in that asks for the person's e-mail and
# name is `form_post`: appleid.apple.com renders a form and submits it to
# /auth/apple/callback. That submission is cross-site, and a browser does not
# attach a `SameSite=Lax` cookie to a cross-site POST — Lax is Rails' default
# and this app's. The cookie that would be withheld is the session, which is
# exactly where OmniAuth put the `state` and the `nonce` it minted one request
# earlier, so the callback would arrive with an empty session and OmniAuth
# would refuse it as csrf_detected. Nobody could ever sign in with Apple.
#
# So the ONE response that has to survive the round trip — the redirect that
# answers the Apple authorize request — has its session cookie re-marked
# `SameSite=None`, and no other response on the site does. Narrow on purpose:
# the whole point of Lax is that a cookie minted here is never handed over on
# a third-party page's say-so, and that stays true everywhere else, including
# the Google door, whose callback is an ordinary top-level redirect and needs
# none of this.
#
# `Secure` rides along whenever the request itself was HTTPS, because browsers
# reject `SameSite=None` without it — and "was HTTPS" is asked of
# `Rack::Request#ssl?`, not of `rack.url_scheme` alone. Behind a TLS-terminating
# proxy (Render's, and any load balancer) the app itself is spoken to over
# plain HTTP and only the `X-Forwarded-Proto` header says the browser was on
# HTTPS; reading the raw scheme would have made the `Secure` flag depend on
# FORCE_SSL being switched on rather than on the request, and a `SameSite=None`
# cookie without `Secure` is dropped by every browser — every Apple sign-in
# would fail as csrf_detected.
#
# Over plain HTTP — a development container, a request spec — it is correctly
# left off: browsers accept a non-Secure cookie from an http:// origin, so the
# dev door still works, and marking it secure would stop the test client (and
# a developer's browser on http://localhost) sending it back at all.
#
# Sits in the stack beside RegistrationGateMiddleware, both ahead of OmniAuth's
# own strategy middleware, so this one sees the response the strategy built.
class AppleFormPostCookieMiddleware
  SET_COOKIE_HEADERS = %w[set-cookie Set-Cookie].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)

    relax_same_site!(env, headers) if apple_authorize_request?(env)

    [status, headers, body]
  end

  private

  # The request phase and nothing else: /auth/apple exactly. The callback that
  # comes back needs no help — by then the cookie has already been sent.
  def apple_authorize_request?(env)
    env['PATH_INFO'].to_s == "#{OmniAuth.config.path_prefix}/#{RegistrationGateMiddleware::APPLE_PROVIDER}"
  end

  def relax_same_site!(env, headers)
    name = SET_COOKIE_HEADERS.find { |header| headers[header].present? }

    return if name.nil?

    secure = Rack::Request.new(env).ssl?
    cookies = headers[name]
    rewritten = Array.wrap(cookies).map { |cookie| rewrite(cookie, secure:) }

    headers[name] = cookies.is_a?(Array) ? rewritten : rewritten.join("\n")
  end

  # Only the session cookie. Anything else the response happens to set (a
  # locale, a flash) has nothing to do with the round trip through Apple.
  def rewrite(cookie, secure:)
    return cookie unless cookie.to_s.start_with?("#{session_cookie_name}=")

    cookie = cookie.sub(/;\s*SameSite=\w+/i, '')
    cookie += '; SameSite=None'
    cookie += '; secure' if secure && !cookie.match?(/;\s*secure(;|\z)/i)

    cookie
  end

  def session_cookie_name
    @session_cookie_name ||= Rails.application.config.session_options[:key]
  end
end
