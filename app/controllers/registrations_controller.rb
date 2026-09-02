# frozen_string_literal: true

# Self-serve sign-up by email and password (docs/signup.md). Only `new`,
# `create` and the check-your-email page exist — edit/update/destroy are not
# routed. Every create runs the abuse guards in order — Turnstile, then the
# form's own checks (the disposable-address blocklist among them), then the
# per-IP limit — before anything is written, saves the account and its admin
# in one transaction, and never signs the user in: Devise mails a
# confirmation link and the person signs in after opening it. The per-IP
# limit counts sign-ups, not attempts: it is spent only once the CAPTCHA and
# the validation have passed, so five typos from one office never lock the
# office out.
class RegistrationsController < Devise::RegistrationsController
  include LaunchGates

  TURNSTILE_HOST = 'https://challenges.cloudflare.com'

  before_action :require_registration_enabled!
  # Runs after ApplicationController#set_csp (same condition), so the policy
  # it appends to is the one the response will carry. Registration-only:
  # the global policy never allows a third-party script.
  before_action :allow_turnstile, if: -> { request.get? && !request.headers['HTTP_X_TURBO'] }

  around_action :with_browser_locale

  def new
    build_signup

    render :new
  end

  def create
    build_signup(sign_up_params)

    return refuse(:unprocessable_content) unless turnstile_verified?
    return refuse(:unprocessable_content) unless @user.valid?(:registration)
    return refuse(:too_many_requests) unless ip_allowed?

    if save_signup
      session[:signup_email] = @user.email

      redirect_to after_inactive_sign_up_path_for(@user), status: :see_other
    else
      refuse(:unprocessable_content)
    end
  end

  # "Check your email": what was sent and where. The address is kept for
  # this one page only; the copy still reads right without it (a reload).
  def confirm
    @signup_email = session.delete(:signup_email)
  end

  private

  def build_signup(attrs = {})
    @name = attrs[:name].to_s
    @user = Registrations.build_signup(name: @name, email: attrs[:email], password: attrs[:password],
                                       timezone: attrs[:timezone])

    self.resource = @user
  end

  def refuse(status)
    clean_up_passwords(@user)

    render :new, status:
  end

  # The DB transaction is the user save: belongs_to autosaves the new account
  # first, and a validation failure (taken email, short password, disposable
  # address) writes nothing. The confirmation mail goes out from Devise's
  # after_commit, through the platform mail server (devise_mail override).
  def save_signup
    @user.save(context: :registration)
  rescue ActiveRecord::RecordNotUnique
    # Two sign-ups for one address at the same moment: the loser hits the
    # unique index instead of the validation, and is told the same thing.
    @user.errors.add(:email, :taken)

    false
  end

  def ip_allowed?
    Registrations.assert_ip_allowed!(request.remote_ip)

    true
  rescue RateLimit::LimitApproached
    @user.errors.add(:base, I18n.t('too_many_sign_ups_from_this_network'))

    false
  end

  def turnstile_verified?
    Turnstile.verify!(params['cf-turnstile-response'], request.remote_ip)

    true
  rescue Turnstile::VerificationFailed
    @user.errors.add(:base, I18n.t('please_complete_the_verification'))

    false
  end

  def sign_up_params
    return {} unless params[:user].respond_to?(:permit)

    params.require(:user).permit(:name, :email, :password, :timezone)
  end

  def after_inactive_sign_up_path_for(_resource)
    confirm_registration_path
  end

  def allow_turnstile
    policy = request.content_security_policy

    return unless policy

    policy.script_src(*policy.directives['script-src'], TURNSTILE_HOST)
    policy.frame_src(*policy.directives['frame-src'], TURNSTILE_HOST)
  end
end
