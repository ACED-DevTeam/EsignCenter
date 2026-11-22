# frozen_string_literal: true

# Writes the page-view tally a controller decided on (MarketingPageViews),
# once the response is final.
#
# It sits OUTSIDE Rack::ConditionalGet for one reason: a controller that
# rendered a page sees a 200, but a browser that already holds that page asks
# with If-None-Match, and the conditional-GET middleware then answers 304 and
# sends nothing. Nobody was shown a page, so nothing is counted — and only
# something further out than that middleware can know.
#
# The controller leaves the decided tally in the request env; this adds one to
# the counter when what finally went out was a 200. MarketingAdmin::Traffic
# gives the write a short time budget and never raises, and anything
# unexpected here is reported and swallowed: the visitor's response is
# returned exactly as the app produced it, whatever the counter did.
class MarketingPageViewsMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    response = @app.call(env)

    tally(env, response.first)

    response
  end

  private

  def tally(env, status)
    decided = env[MarketingAdmin::Traffic::ENV_KEY]

    MarketingAdmin::Traffic.increment!(**decided) if decided && status.to_i == 200
  rescue StandardError => e
    ErrorReport.error(e)
  end
end
