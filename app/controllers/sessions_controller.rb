# frozen_string_literal: true

class SessionsController < Devise::SessionsController
  before_action :configure_permitted_parameters

  around_action :with_browser_locale

  def create
    email = sign_in_params[:email].to_s.downcase

    # An unknown email falls through to Devise's generic "invalid email or
    # password" answer, so sign-in never reveals which addresses exist.
    if User.exists?(email:, otp_required_for_login: true) && sign_in_params[:otp_attempt].blank?
      return render :otp, locals: { resource: User.new(sign_in_params) }, status: :unprocessable_content
    end

    super { |user| note_password_sign_in(user) }
  end

  # Signing out ends a support session too, and ends it PROPERLY: the audit row
  # that says how long an operator was inside a customer's account is written
  # here, before Warden clears the session, because afterwards there is nothing
  # left to write it from. Belt and braces with the sign-out itself — Warden
  # resets the session, so the impersonation cookie cannot survive either way.
  def destroy
    state = support_impersonation

    end_support_impersonation!(state, ended_by: 'sign_out') if state.present? && true_user.present?

    super
  end

  private

  # For the private marketing page only (MarketingAdmin::MailboxProof): a
  # session opened with the login's own password is one of the few that page
  # accepts. Written for an address on its list and for nobody else, and only
  # when it really was the password that signed them in — not the remember-me
  # cookie, which Warden would also accept here.
  def note_password_sign_in(user)
    return unless warden.winning_strategy.is_a?(Devise::Strategies::DatabaseAuthenticatable)

    MarketingAdmin::MailboxProof.record!(warden, user, MarketingAdmin::MailboxProof::PASSWORD)
  end

  def after_sign_in_path_for(...)
    return params[:redir] if params[:redir].present?

    super
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_in, keys: [:otp_attempt])
  end

  def set_flash_message(key, kind, options = {})
    return if key == :alert && kind == 'already_authenticated'

    super
  end
end
