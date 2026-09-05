# frozen_string_literal: true

# The public help centre: /help and /help/<slug> (Session 10 Phase B).
#
# Public in exactly the way MarketingController and LegalController are — no
# login, no first-run setup redirect, no authorization check — because the
# people who most need it are a signer who has never had an account and a
# visitor deciding whether to make one. English-only in the marketing layout
# (ApplicationController#with_english), like every other public page.
#
# The table of contents is HelpCenter (lib/help_center.rb); the prose is a
# partial per slug under app/views/help/articles.
class HelpController < ApplicationController
  layout 'marketing'

  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_english

  # A slug nobody has written is a 404, not a 500 — the same answer
  # LegalController gives for an unknown document.
  rescue_from HelpCenter::UnknownArticle do
    raise ActionController::RoutingError, 'Not Found'
  end

  def index
    @sections = HelpCenter.sections
  end

  def show
    @article = HelpCenter.article!(params[:slug])
    @previous_article, @next_article = HelpCenter.neighbours(@article)
  end
end
