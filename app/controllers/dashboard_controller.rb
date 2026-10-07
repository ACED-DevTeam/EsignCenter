# frozen_string_literal: true

class DashboardController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[index]

  before_action :maybe_render_landing
  before_action :maybe_redirect_mfa_setup
  before_action :maybe_redirect_name_prompt

  skip_authorization_check

  def index
    if cookies.permanent[:dashboard_view] == 'submissions'
      SubmissionsDashboardController.dispatch(:index, request, response)
    else
      TemplatesDashboardController.dispatch(:index, request, response)
    end
  end

  private

  def maybe_redirect_mfa_setup
    return unless signed_in?
    return if current_user.otp_required_for_login

    return if !current_user.otp_required_for_login && !AccountConfig.exists?(value: true,
                                                                             account_id: current_user.account_id,
                                                                             key: AccountConfig::FORCE_MFA)

    redirect_to mfa_setup_path, notice: I18n.t('setup_2fa_to_continue')
  end

  # An account still named after its owner's email address asks them for a
  # name, once (NamePromptsController). Never during a support session — the
  # name is the customer's to give — and never for an account that could not
  # save it anyway (frozen or suspended), which would only loop.
  def maybe_redirect_name_prompt
    return unless signed_in?
    return if support_impersonation?
    return unless Registrations.name_missing?(current_user)
    return unless can?(:update, current_account)

    redirect_to name_prompt_path
  end

  def maybe_render_landing
    return if signed_in?

    # The public landing page (Session 9), in the marketing layout the
    # pricing, trust and legal pages share, and in English like them.
    with_english { render 'marketing/landing', layout: 'marketing' }
  end
end
