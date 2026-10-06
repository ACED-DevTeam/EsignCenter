# frozen_string_literal: true

class NormalizeClientIpMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    # No proxy of ours sets these headers, so drop them outright. Rack 3 prefers
    # Forwarded over X-Forwarded-For, while Client-Ip can make Rails raise.
    env.delete('HTTP_FORWARDED')
    env.delete('HTTP_CLIENT_IP')

    @app.call(env)
  end
end
