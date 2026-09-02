# frozen_string_literal: true

# Sits in front of OmniAuth's strategy middleware (Devise adds that one at the
# end of the stack, after the initializers ran). With REGISTRATION_ENABLED off
# the whole OmniAuth path prefix is a 404 — the same answer the registration
# and confirmation controllers give — so no request phase ever starts and no
# browser is bounced to Google while sign-up is closed.
class RegistrationGateMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) if Docuseal.registration_enabled? || !omniauth_path?(env['PATH_INFO'].to_s)

    [404, { 'Content-Type' => 'text/plain', 'Content-Length' => '0' }, []]
  end

  private

  def omniauth_path?(path)
    prefix = OmniAuth.config.path_prefix.to_s

    prefix.present? && (path == prefix || path.start_with?("#{prefix}/"))
  end
end
