# frozen_string_literal: true

# "Continue with Google" (docs/signup.md). Google hands back a verified email;
# an existing user with that address signs in (an unconfirmed one has its
# password replaced and is then confirmed — Google already proved the
# mailbox, but nobody ever proved it before), a stranger gets a
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

    adopt(user) unless user.confirmed?

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

  # Adopting an unconfirmed row: the password on it dies first, then the row
  # is confirmed. An unconfirmed row is proof that nobody ever opened a link
  # at that mailbox, so the person who typed the address into the sign-up
  # form may be a stranger who typed someone else's — and the password on the
  # row is theirs, not the owner's. Google has just proved the mailbox
  # belongs to the person in front of us, so the row is theirs to keep; but
  # confirming it while the stranger's password still works would hand that
  # stranger a working sign-in at /sign_in to everything the owner goes on to
  # create. A random password nobody holds ends that: the owner sets their
  # own from "Forgot your password?", exactly like a stranger who signs up
  # with Google in the first place (see `register`). Written before the
  # confirm, and without validations, so nothing can leave the old password
  # alive on a confirmed row. A user who is ALREADY confirmed is the opposite
  # case — they proved the mailbox themselves, so the password is their own
  # and is never touched.
  def adopt(user)
    user.password = Devise.friendly_token
    user.save!(validate: false)

    user.confirm
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
    # The versions the button was displaying ride on the authorize request's
    # query string, exactly as the browser timezone does, and OmniAuth hands
    # that query back here as `omniauth.params`. A button drawn before a
    # wording change therefore cannot record an agreement to the new text: the
    # person is sent back to sign in and asked to read it.
    #
    # Asked BEFORE the per-network sign-up budget, which is only ever spent on
    # a sign-up that really happened (lib/registrations.rb): a refusal that
    # writes nothing must not use up an allowance an honest visitor behind the
    # same address is going to need.
    versions = LegalDocuments.submitted_versions(request.env['omniauth.params'])

    return refuse(I18n.t('legal_documents_updated_please_review')) unless LegalDocuments.current_versions?(versions)

    Registrations.assert_ip_allowed!(request.remote_ip)

    user = Registrations.build_signup(name: auth.info.name, email:, password: Devise.friendly_token,
                                      timezone: request.env.dig('omniauth.params', 'timezone'))
    user.skip_confirmation!

    return user if Registrations.save_signup(user, request:, source: LegalAcceptance::SIGNUP_GOOGLE,
                                                   versions:)

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

  def refuse(message)
    redirect_to new_user_session_path, alert: message, status: :see_other
  end
end
