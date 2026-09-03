# frozen_string_literal: true

# Sits in front of OmniAuth's strategy middleware (Devise adds that one at the
# end of the stack, after the initializers ran). With REGISTRATION_ENABLED off
# the whole OmniAuth path prefix is a 404 — the same answer the registration
# and confirmation controllers give — so no request phase ever starts and no
# browser is bounced to Google while sign-up is closed. The Google endpoints
# are a 404 as well while the Google credentials are unset: with no client
# id there is nothing to bounce to, only a broken redirect.
#
# It is also where the per-network attempt ceiling for those endpoints lives.
# OmniAuth's strategy performs its own outbound token exchange with Google
# during the callback, before any controller of ours is reached, so a stranger
# replaying callbacks with a junk code would hold a web thread per request no
# matter what our controllers do. Only something in front of the strategy can
# refuse that, and this middleware already is. ActionDispatch::RemoteIp has
# run by the time the stack reaches here (this one is appended last), so the
# client address is the trustworthy one, not whatever a header claimed — and
# for the same reason the session middleware has already run, so the state
# OmniAuth stored in the browser is readable from env['rack.session'].
#
# That ceiling is spent by ONE request and no other: the provider's callback
# carrying a `state` that matches the one the strategy put in this browser's
# session. Nothing else can reach the token exchange — a stray /auth/anything
# never routes, and the request phase only builds a redirect URL — so nothing
# else is counted. It has to be that narrow: an attempt counter that any
# request under the prefix could spend is a weapon pointed at our own users,
# because a malicious page can make an innocent visitor's browser issue those
# requests cross-origin (a handful of <img> tags will do) and burn that
# visitor's — or a whole office's — Google sign-in allowance for the hour.
# A third-party page cannot read or set the session's OmniAuth state, so only
# someone driving the flow in their own browser can spend a count.
class RegistrationGateMiddleware
  GOOGLE_PROVIDER = 'google_oauth2'
  OMNIAUTH_STATE_SESSION_KEY = 'omniauth.state'

  def initialize(app)
    @app = app
  end

  def call(env)
    path = env['PATH_INFO'].to_s

    return @app.call(env) unless omniauth_path?(path)
    return refusal(404) unless open?(path)
    return refusal(429) if token_exchange_request?(env, path) && !attempt_allowed?(env)

    @app.call(env)
  end

  private

  def open?(path)
    Docuseal.registration_enabled? && (!google_path?(path) || Registrations.google_enabled?)
  end

  # The callback with a state OmniAuth itself minted for this session: the one
  # request the strategy answers by calling out to Google's token endpoint.
  # Read, never deleted — the strategy consumes the stored state itself, a
  # step further down the stack. `params` and not `GET` so a state posted in
  # the body counts too, exactly as the strategy reads it.
  def token_exchange_request?(env, path)
    return false unless path == callback_path

    state = ActionDispatch::Request.new(env).params['state'].to_s
    stored = env['rack.session'].presence&.[](OMNIAUTH_STATE_SESSION_KEY).to_s

    state.present? && stored.present? && ActiveSupport::SecurityUtils.secure_compare(state, stored)
  end

  # Redis down means the limit is off, never the door (RateLimit fails open by
  # design); LimitApproached is the only thing to catch here.
  def attempt_allowed?(env)
    Registrations.assert_oauth_attempt_allowed!(ActionDispatch::Request.new(env).remote_ip)

    true
  rescue RateLimit::LimitApproached
    false
  end

  def refusal(status)
    [status, { 'Content-Type' => 'text/plain', 'Content-Length' => '0' }, []]
  end

  def omniauth_path?(path)
    prefix = OmniAuth.config.path_prefix.to_s

    prefix.present? && (path == prefix || path.start_with?("#{prefix}/"))
  end

  def google_path?(path)
    path == google_prefix || path.start_with?("#{google_prefix}/")
  end

  def google_prefix
    "#{OmniAuth.config.path_prefix}/#{GOOGLE_PROVIDER}"
  end

  def callback_path
    "#{google_prefix}/callback"
  end
end
