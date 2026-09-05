# frozen_string_literal: true

# Self-serve sign-up by email and password (docs/signup.md). Only `new`,
# `create` and the check-your-email page exist — edit/update/destroy are not
# routed. Every create runs the abuse guards in order — the per-IP attempt
# ceiling, then Turnstile, then the form's own checks (the disposable-address
# blocklist among them), then the per-IP sign-up budget — before anything is
# written, saves the account, its admin and the person's agreement to the
# Terms and the Privacy Policy in one transaction, and never
# signs the user in: Devise mails a confirmation link and the person signs in
# after opening it. The two per-IP limits are different things and the order
# is the point of both: the budget counts sign-ups and is spent only once the
# CAPTCHA and the validation have passed, so five typos from one office never
# lock the office out; the ceiling counts attempts and is spent first,
# because everything after it — the Cloudflare call above all — costs the
# server real work that an anonymous stranger must not be able to order in
# bulk.
class RegistrationsController < Devise::RegistrationsController
  include LaunchGates

  TURNSTILE_HOST = 'https://challenges.cloudflare.com'

  before_action :require_registration_enabled!
  # Runs after ApplicationController#set_csp (same condition), so the policy
  # it appends to is the one the response will carry. The sign-up form is the
  # only page that carries the widget, so it is the only page whose policy is
  # widened — the check-your-email page and the global policy never allow a
  # third-party script. (`create` re-renders `new` on a refusal, but set_csp
  # itself only runs on GET, so there is no policy to widen there.)
  before_action :allow_turnstile, only: %i[new],
                                  if: -> { request.get? && !request.headers['HTTP_X_TURBO'] }

  around_action :with_browser_locale

  def new
    build_signup

    render :new
  end

  def create
    build_signup(sign_up_params)

    return refuse(:too_many_requests) unless ip_attempt_allowed?
    return refuse(:unprocessable_content) unless turnstile_verified?
    return refuse(:unprocessable_content) unless @user.valid?(:registration)
    return refuse(:unprocessable_content) unless legal_versions_current?
    return refuse(:too_many_requests) unless ip_allowed?

    # The confirmation mail goes out from Devise's after_commit, through the
    # platform mail server (devise_mail override).
    if Registrations.save_signup(@user, request:, source: LegalAcceptance::SIGNUP_EMAIL,
                                        versions: legal_versions)
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

  def ip_allowed?
    Registrations.assert_ip_allowed!(request.remote_ip)

    true
  rescue RateLimit::LimitApproached
    over_limit

    false
  end

  # The attempt ceiling, checked before the Cloudflare round-trip so that a
  # refused network costs us nothing but a render: the whole point of it is
  # that no stranger can make us hold a web thread on an outbound call they
  # can replay for free. Deliberately not merged with the budget above — that
  # one counts sign-ups and is spent only on success, this one counts tries.
  def ip_attempt_allowed?
    Registrations.assert_ip_attempt_allowed!(request.remote_ip)

    true
  rescue RateLimit::LimitApproached
    over_limit

    false
  end

  # Both per-network refusals say the same thing to the visitor: they are one
  # network being asked to come back later, and which counter ran out is our
  # business, not theirs.
  def over_limit
    @user.errors.add(:base, I18n.t('too_many_sign_ups_from_this_network'))
  end

  # The version of each legal document the form was DISPLAYING, sent back in a
  # hidden field. Checked before anything is written, so somebody who had the
  # page open across a wording change is asked to read the new one rather than
  # being recorded as having agreed to it (LegalDocuments::StaleVersionError).
  # A body with no versions in it at all is stale too: an old client must not
  # be able to skip the check by staying silent.
  def legal_versions
    LegalDocuments.submitted_versions(params)
  end

  def legal_versions_current?
    return true if LegalDocuments.current_versions?(legal_versions)

    @user.errors.add(:base, I18n.t('legal_documents_updated_please_review'))

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
