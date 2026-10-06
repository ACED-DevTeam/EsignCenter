# frozen_string_literal: true

# Sits in front of OmniAuth's strategy middleware (Devise adds that one at the
# end of the stack, after the initializers ran). With REGISTRATION_ENABLED off
# the whole OmniAuth path prefix is a 404 — the same answer the registration
# and confirmation controllers give — so no request phase ever starts and no
# browser is bounced to a provider while sign-up is closed. A provider's own
# endpoints are a 404 as well while its credentials are unset: with no client
# id there is nothing to bounce to, only a broken redirect. Both providers,
# Google and Apple, are gated by exactly the same two questions.
#
# It is also where the per-network attempt ceiling for those endpoints lives.
# OmniAuth's strategy performs its own outbound token exchange with the
# provider during the callback, before any controller of ours is reached, so a
# stranger replaying callbacks with a junk code would hold a web thread per
# request no matter what our controllers do. Only something in front of the
# strategy can refuse that, and this middleware already is.
# ActionDispatch::RemoteIp has run by the time the stack reaches here (this one
# is appended last), so the client address is the trustworthy one, not whatever
# a header claimed — and for the same reason the session middleware has already
# run, so the state OmniAuth stored in the browser is readable from
# env['rack.session'].
#
# That ceiling is spent by ONE request and no other: a provider's callback
# carrying a `state` that matches the one the strategy put in this browser's
# session. Nothing else can reach the token exchange — a stray /auth/anything
# never routes, and the request phase only builds a redirect URL — so nothing
# else is counted. It has to be that narrow: an attempt counter that any
# request under the prefix could spend is a weapon pointed at our own users,
# because a malicious page can make an innocent visitor's browser issue those
# requests cross-origin (a handful of <img> tags will do) and burn that
# visitor's — or a whole office's — sign-in allowance for the hour.
# A third-party page cannot read or set the session's OmniAuth state, so only
# someone driving the flow in their own browser can spend a count.
#
# Apple reads its `state` out of the POST body rather than the query string
# (its callback is a form POST, not a redirect), which is why the check below
# reads `params` and not `GET`.
class RegistrationGateMiddleware
  GOOGLE_PROVIDER = 'google_oauth2'
  APPLE_PROVIDER = 'apple'

  # Provider name => the question Registrations answers about its credentials.
  PROVIDERS = { GOOGLE_PROVIDER => :google_enabled?, APPLE_PROVIDER => :apple_enabled? }.freeze

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
    return false unless Docuseal.registration_enabled?

    provider = provider_for(path)

    provider.nil? || Registrations.public_send(PROVIDERS.fetch(provider))
  end

  # The callback with a state OmniAuth itself minted for this session: the one
  # request the strategy answers by calling out to the provider's token
  # endpoint. Read, never deleted — the strategy consumes the stored state
  # itself, a step further down the stack. `params` and not `GET` so a state
  # posted in the body counts too (Apple's callback is a form POST), exactly
  # as the strategy reads it.
  def token_exchange_request?(env, path)
    return false unless callback_paths.include?(path)

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

  # Which provider a path belongs to, or nil for the prefix itself and for
  # anything under it that is nobody's (those keep passing through, exactly as
  # they did when Google was the only provider).
  def provider_for(path)
    PROVIDERS.each_key.find do |provider|
      prefix = provider_prefix(provider)

      path == prefix || path.start_with?("#{prefix}/")
    end
  end

  def provider_prefix(provider)
    "#{OmniAuth.config.path_prefix}/#{provider}"
  end

  def callback_paths
    PROVIDERS.each_key.map { |provider| "#{provider_prefix(provider)}/callback" }
  end
end
