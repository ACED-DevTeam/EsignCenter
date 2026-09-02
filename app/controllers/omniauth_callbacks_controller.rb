# frozen_string_literal: true

# "Continue with Google" (docs/signup.md). Google hands back a verified email;
# an existing user with that address signs in (an unconfirmed one is
# confirmed first — Google already proved the mailbox), a stranger gets a
# new customer account behind the same per-IP and blocklist guards as the
# email path (no Turnstile: Google gated the request). A user who enrolled
# two-factor authentication is sent to the password form instead — the
# one-time code is entered there and Google never bypasses it; a user whose
# sign-in is locked (too many wrong passwords) is refused the same way.
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

    # Devise's own gate (a lockout above all): the reason in Devise's words.
    return refuse(inactive_message_for(user)) unless user.active_for_authentication?

    sign_in_and_redirect user, event: :authentication
  end

  def failure
    refuse(I18n.t('google_sign_in_failed'))
  end

  private

  def email_verified?(auth)
    auth.extra&.raw_info&.email_verified == true
  end

  def inactive_message_for(user)
    I18n.t(user.inactive_message, scope: 'devise.failure', default: I18n.t('google_sign_in_failed'))
  end

  # A stranger: a new customer account whose admin is confirmed at once
  # (Google verified the address) with a random password they can reset
  # later from the sign-in page. The browser's timezone rides on the
  # authorize request's query string (devise/shared/_google_button), which
  # OmniAuth hands back here as omniauth.params.
  def register(email, auth)
    Registrations.assert_ip_allowed!(request.remote_ip)

    user = Registrations.build_signup(name: auth.info.name, email:, password: Devise.friendly_token,
                                      timezone: request.env.dig('omniauth.params', 'timezone'))
    user.skip_confirmation!

    return user if save_new(user)

    refuse(refusal_message(user))
  rescue RateLimit::LimitApproached
    refuse(I18n.t('too_many_sign_ups_from_this_network'))
  end

  # The blocklist writes a whole sentence on the email field; Devise's
  # "taken" is a fragment that needs its attribute in front.
  def refusal_message(user)
    error = user.errors.first

    return I18n.t('google_sign_in_failed') unless error

    error.type == :taken ? error.full_message : error.message
  end

  # Two sign-ups for one address at the same moment: the loser hits the
  # unique index instead of the validation, and is told the same thing.
  def save_new(user)
    user.save(context: :registration)
  rescue ActiveRecord::RecordNotUnique
    user.errors.add(:email, :taken)

    false
  end

  def refuse(message)
    redirect_to new_user_session_path, alert: message, status: :see_other
  end
end
