# frozen_string_literal: true

# The private marketing page at /admin (docs/marketing-admin.md): how the
# website, sign-ups, the social channels and the outreach are doing.
#
# AUTHORIZATION. Like the operator console, this page is not about the
# viewer's own account — it shows the whole product's numbers — so CanCan's
# per-account check is the wrong question and is skipped deliberately. The
# gate is MarketingAdminAccess: a confirmed, signed-in user whose email is on
# the list.
#
# The gate runs TWICE, and both runs matter:
#
#   * first of all, PREPENDED — before the forgery check can answer a
#     stranger's POST with a 422 and before Devise can answer with a redirect
#     to sign-in. Either would confirm the page is there; a stranger gets the
#     404 a missing page gives, whatever they send;
#   * and again after ApplicationController's own callbacks. The first run
#     steps aside for an operator in a support session, so that the
#     support-session rule can refuse and audit a write the way it does on
#     every other door; this run is what still keeps that operator out.
class MarketingAdminController < ApplicationController
  skip_authorization_check

  prepend_before_action :hide_marketing_admin_from_strangers!
  before_action :require_marketing_admin_access!

  # English only, like the marketing pages the numbers are about.
  around_action :with_english

  def show
    @today = MarketingAdmin.today
    @range = params[:range].to_i
    @traffic = section { MarketingAdmin::Traffic.report(range: @range, today: @today) }
    @product = section { MarketingAdmin::Product.report(today: @today) }
    @social = section { MarketingAdmin::Social.report(today: @today) }
    @outreach = section { MarketingAdmin::Outreach.report(today: @today) }
  end

  # "Refresh now": check every connected app in the background. One check
  # every ten minutes for everybody who can see the page — the apps' request
  # allowances are small and the numbers do not move faster than that.
  def refresh
    if !MarketingAdmin::Social.any_connected?
      redirect_to marketing_admin_path(anchor: 'channels'),
                  alert: 'No apps are connected yet, so there is nothing to check.'
    elsif MarketingAdmin::Social.claim_refresh!
      MarketingSocialSnapshotJob.perform_later(MarketingAdmin::Social::MANUAL_REFRESH)

      redirect_to marketing_admin_path(anchor: 'channels'),
                  notice: 'Checking each app now. Reload this page in a minute to see the new numbers.'
    else
      minutes = (MarketingAdmin::Social.refresh_available_in / 60.0).ceil.clamp(1, 10)

      redirect_to marketing_admin_path(anchor: 'channels'),
                  alert: "Checked a few minutes ago. Try again in #{minutes} #{'minute'.pluralize(minutes)}."
    end
  end

  # TikTok's weekly numbers, typed in from TikTok Studio.
  def tiktok
    MarketingAdmin::Social.record_tiktok!(params.permit(:followers, :total_views, :total_likes, :post_count))

    redirect_to marketing_admin_path(anchor: 'channels'), notice: 'Saved TikTok’s numbers for today.'
  rescue MarketingAdmin::Social::Error => e
    redirect_to marketing_admin_path(anchor: 'channels'), alert: e.message
  end

  private

  # Each section is built on its own, so a problem in one — a query that
  # fails, a table that is missing — shows as a note in that section instead
  # of taking the whole page down with it.
  def section
    yield
  rescue StandardError => e
    ErrorReport.error(e)

    nil
  end
end
