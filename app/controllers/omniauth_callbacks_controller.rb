# frozen_string_literal: true

# "Continue with Google" (docs/signup.md). Google hands back a verified email;
# an existing user with that address signs in (an unconfirmed one is
# confirmed first — Google already proved the mailbox), a stranger gets a
# new customer account behind the same per-IP and blocklist guards as the
# email path (no Turnstile: Google gated the request). A user who enrolled
# two-factor authentication is sent to the password form instead — the
# one-time code is entered there and Google never bypasses it.
class OmniauthCallbacksController < Devise::OmniauthCallbacksController
  include LaunchGates

  before_action :require_registration_enabled!

  around_action :with_browser_locale

  def google_oauth2
    auth = request.env['omniauth.auth']
    email = auth&.info&.email.to_s.strip.downcase

    return refuse(I18n.t('google_email_not_verified')) if email.blank? || !email_verified?(auth)

    user = User.find_by(email:) || register(email, auth)

    return if performed?
    return refuse(I18n.t('google_sign_in_not_available_with_2fa')) if user.otp_required_for_login?
    return refuse(I18n.t('this_account_is_no_longer_active')) if user.archived_at? || user.account.archived_at?

    user.confirm unless user.confirmed?

    sign_in_and_redirect user, event: :authentication
  end

  def failure
    refuse(I18n.t('google_sign_in_failed'))
  end

  private

  def email_verified?(auth)
    auth.extra&.raw_info&.email_verified == true
  end

  # A stranger: a new customer account whose admin is confirmed at once
  # (Google verified the address) with a random password they can reset
  # later from the sign-in page.
  def register(email, auth)
    Registrations.assert_ip_allowed!(request.remote_ip)

    user = Registrations.build_signup(name: auth.info.name, email:, password: Devise.friendly_token, timezone: nil)
    user.skip_confirmation!

    return user if user.save(context: :registration)

    refuse(user.errors.map(&:message).first || I18n.t('google_sign_in_failed'))
  rescue RateLimit::LimitApproached
    refuse(I18n.t('too_many_sign_ups_from_this_network'))
  end

  def refuse(message)
    redirect_to new_user_session_path, alert: message, status: :see_other
  end
end
