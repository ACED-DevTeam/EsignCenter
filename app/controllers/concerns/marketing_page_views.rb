# frozen_string_literal: true

# Counts a view of a public page for the marketing page at /admin
# (MarketingAdmin::Traffic, which says exactly what is and is not kept).
#
# A controller opts its public pages in:
#
#   include MarketingPageViews
#   count_marketing_page_views only: %i[pricing trust]
#
# A view is counted when a signed-out person's browser gets the finished page:
# a GET answered 200 with HTML. Signed-in people are not counted (they are
# customers using the product, not visitors being marketed to), nor are bots,
# link previews, prefetches, redirects or error pages.
#
# The landing page is rendered from a before_action, which stops the callback
# chain before any after_action could run — DashboardController calls
# `count_marketing_page_view` itself, right after it renders.
#
# Nothing is written here. The controller only DECIDES the tally and leaves it
# in the request env; MarketingPageViewsMiddleware writes it once the final
# status is known, because a conditional GET can still turn this 200 into a
# 304 after the controller has finished. And nothing here may raise: working
# out a tally reads what a stranger sent, and a page must never fail because
# the counter could not make sense of it.
module MarketingPageViews
  extend ActiveSupport::Concern

  class_methods do
    def count_marketing_page_views(**)
      after_action(:count_marketing_page_view, **)
    end
  end

  private

  def count_marketing_page_view
    decide_marketing_tally { MarketingAdmin::Traffic.view_tally(request) }
  end

  # The sign-up page counts as "opened the sign-up page" rather than as one
  # more page view: it is the step the marketing pages exist to lead to.
  def count_marketing_signup_open
    decide_marketing_tally { MarketingAdmin::Traffic.signup_open_tally(request) }
  end

  def decide_marketing_tally
    return unless marketing_page_view_countable?

    request.set_header(MarketingAdmin::Traffic::ENV_KEY, yield)
  rescue StandardError => e
    ErrorReport.error(e)
  end

  def marketing_page_view_countable?
    response.status == 200 && response.media_type == 'text/html' && !signed_in? &&
      MarketingAdmin::Traffic.countable?(request)
  end
end
