# frozen_string_literal: true

# Sits in front of OmniAuth's strategy middleware (Devise adds that one at the
# end of the stack, after the initializers ran). With REGISTRATION_ENABLED off
# the whole OmniAuth path prefix is a 404 — the same answer the registration
# and confirmation controllers give — so no request phase ever starts and no
# browser is bounced to Google while sign-up is closed. The Google endpoints
# are a 404 as well while the Google credentials are unset: with no client
# id there is nothing to bounce to, only a broken redirect.
class RegistrationGateMiddleware
  GOOGLE_PROVIDER = 'google_oauth2'

  def initialize(app)
    @app = app
  end

  def call(env)
    path = env['PATH_INFO'].to_s

    return @app.call(env) unless omniauth_path?(path)
    return @app.call(env) if Docuseal.registration_enabled? && (!google_path?(path) || Registrations.google_enabled?)

    [404, { 'Content-Type' => 'text/plain', 'Content-Length' => '0' }, []]
  end

  private

  def omniauth_path?(path)
    prefix = OmniAuth.config.path_prefix.to_s

    prefix.present? && (path == prefix || path.start_with?("#{prefix}/"))
  end

  def google_path?(path)
    google_prefix = "#{OmniAuth.config.path_prefix}/#{GOOGLE_PROVIDER}"

    path == google_prefix || path.start_with?("#{google_prefix}/")
  end
end
