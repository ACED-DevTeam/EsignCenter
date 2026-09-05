# frozen_string_literal: true

# The public pricing and trust pages (Session 9). Anyone may read them — no
# login and no first-run setup redirect, like VerifyController — and they say
# nothing about the visitor: the pricing table is rendered from
# lib/pricing_matrix.rb, so what we sell is whatever the code enforces.
# The signed-out landing page is DashboardController#maybe_render_landing,
# rendered in the same layout.
class MarketingController < ApplicationController
  layout 'marketing'

  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_english

  def pricing; end

  def trust; end
end
