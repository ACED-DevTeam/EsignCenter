# frozen_string_literal: true

# "Continue with Google" and "Continue with Apple" (docs/signup.md). Both
# providers hand back a verified email; an existing user with that address
# signs in (an unconfirmed one has its password replaced and is then confirmed
# — the provider already proved the mailbox, but nobody ever proved it
# before), a stranger gets a new customer account behind the same per-IP and
# blocklist guards as the email path (no Turnstile: the provider gated the
# request). A user who enrolled two-factor authentication is sent to the
# password form instead — the one-time code is entered there and no provider
# ever bypasses it; a user whose sign-in is locked (too many wrong passwords)
# is refused the same way.
#
# The two doors are the same door: everything after "we have a verified
# address" is `complete`, written once, so the second provider cannot drift
# away from the first.
class OmniauthCallbacksController < Devise::OmniauthCallbacksController
  include LaunchGates

  # The stem of every message a provider owns: `google_sign_in_failed`,
  # `apple_sign_in_failed`, and so on.
  GOOGLE = 'google'
  APPLE = 'apple'

  # Apple's callback is a cross-site form POST made by appleid.apple.com, so it
  # carries no authenticity token and could not: the form is Apple's, not ours.
  # What stands in the token's place is the `state` OmniAuth minted for this
  # browser and stored in its session — the strategy checks it before this
  # controller is reached, and RegistrationGateMiddleware counts that one
  # request against the per-network ceiling. Google's callback is an ordinary
  # top-level redirect (GET) and needs no exemption.
  #
  # The exemption is keyed on the REQUEST, not on the action name, because
  # Apple sends every outcome of its sheet to the same address by the same
  # verb: a success, a tapped Cancel (`error=user_cancelled_authorize`) and a
  # strategy refusal (`csrf_detected`, `invalid_credentials`) are all that one
  # cross-site POST. A failure is handed to `#failure` inside that very POST —
  # OmniAuth's on_failure hook runs this controller on the callback's own env —
  # so `only: :apple` would have left everybody who cancels on the 422 page.
  # `request.post?` plus the exact callback path is the tightest predicate that
  # covers both actions: a GET to the same path, and a POST anywhere else,
  # still needs a token. (`omniauth.error.strategy` exists only on the failure
  # path, so it would have to be paired with the action name — and a skip with
  # two conditions is OR-ed, not AND-ed, by ActiveSupport.)
  skip_before_action :verify_authenticity_token, if: :apple_callback_post?

  before_action :require_registration_enabled!

  around_action :with_browser_locale

  def google_oauth2
    auth = request.env['omniauth.auth']
    email = provided_email(auth)

    return refuse(I18n.t('google_email_not_verified')) if email.blank? || !google_email_verified?(auth)

    complete(email:, name: auth.info.name, source: LegalAcceptance::SIGNUP_GOOGLE, provider: GOOGLE)
  end

  # Apple only ever sends the e-mail address (and the name) on the FIRST
  # authorisation. Every later sign-in carries the `sub` claim and nothing
  # else, which is fine for somebody we already created — except that we key
  # accounts on the address, not on `sub`. So a re-authorisation for a person
  # we never managed to create (their first attempt fell over: a rate limit, a
  # blocked address, a stale Terms version) arrives with no address at all,
  # and there is nothing to sign them in as and nothing honest to create.
  # Apple's own remedy is the only one: forget the app in the Apple ID
  # settings, which makes the next attempt a first authorisation again. That
  # is what the message says. Nothing here ever invents an address.
  #
  # The address may be one of Apple's private relay forwards
  # (…@privaterelay.appleid.com). It is a real, deliverable mailbox and is
  # stored exactly like any other; nothing about it is special-cased.
  def apple
    auth = request.env['omniauth.auth']
    email = provided_email(auth)

    return refuse(no_email_from_apple_message) if email.blank?
    return refuse(I18n.t('apple_email_not_verified')) unless auth.info.email_verified

    complete(email:, name: auth.info.name, source: LegalAcceptance::SIGNUP_APPLE, provider: APPLE)
  end

  def failure
    refuse(I18n.t("#{failed_provider}_sign_in_failed"))
  end

  private

  # Everything after "this provider has proved this address": one path, so the
  # Apple door and the Google door cannot answer the same situation
  # differently. `provider` only picks the wording of a refusal.
  def complete(email:, name:, source:, provider:)
    user = User.find_by(email:) || register(email:, name:, source:, provider:)

    return if performed?
    return refuse(I18n.t("#{provider}_sign_in_not_available_with_2fa")) if user.otp_required_for_login?
    return refuse(I18n.t('this_account_is_no_longer_active')) if user.archived_at? || user.account.archived_at?

    adopt(user) unless user.confirmed?

    # Devise's own gate (a lockout above all): the reason in Devise's words.
    return refuse(inactive_message_for(user, provider)) unless user.active_for_authentication?

    sign_in_and_redirect user, event: :authentication
  end

  def provided_email(auth)
    auth&.info&.email.to_s.strip.downcase
  end

  def no_email_from_apple_message
    I18n.t('apple_did_not_share_an_email_address', product_name: Docuseal.product_name)
  end

  def google_email_verified?(auth)
    auth.extra&.raw_info&.email_verified == true
  end

  # Adopting an unconfirmed row: the password on it dies first, then the row
  # is confirmed. An unconfirmed row is proof that nobody ever opened a link
  # at that mailbox, so the person who typed the address into the sign-up
  # form may be a stranger who typed someone else's — and the password on the
  # row is theirs, not the owner's. The provider has just proved the mailbox
  # belongs to the person in front of us, so the row is theirs to keep; but
  # confirming it while the stranger's password still works would hand that
  # stranger a working sign-in at /sign_in to everything the owner goes on to
  # create. A random password nobody holds ends that: the owner sets their
  # own from "Forgot your password?", exactly like a stranger who signs up
  # with Google or Apple in the first place (see `register`). Written before
  # the confirm, and without validations, so nothing can leave the old
  # password alive on a confirmed row. A user who is ALREADY confirmed is the
  # opposite case — they proved the mailbox themselves, so the password is
  # their own and is never touched.
  def adopt(user)
    user.password = Devise.friendly_token
    user.save!(validate: false)

    user.confirm
  end

  def inactive_message_for(user, provider)
    I18n.t(user.inactive_message, scope: 'devise.failure', default: I18n.t("#{provider}_sign_in_failed"))
  end

  # A stranger: a new customer account whose admin is confirmed at once (the
  # provider verified the address) with a random password they can reset later
  # from the sign-in page. The browser's timezone rides on the authorize
  # request's query string (devise/shared/_google_button,
  # devise/shared/_apple_button), which OmniAuth hands back here as
  # omniauth.params.
  def register(email:, name:, source:, provider:)
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

    user = Registrations.build_signup(name:, email:, password: Devise.friendly_token,
                                      timezone: request.env.dig('omniauth.params', 'timezone'))
    user.skip_confirmation!

    return user if Registrations.save_signup(user, request:, source:, versions:)

    refuse(refusal_message(user, provider))
  rescue RateLimit::LimitApproached
    refuse(I18n.t('too_many_sign_ups_from_this_network'))
  end

  # The blocklist writes a whole sentence on the email field; Devise's
  # "taken" is a fragment that needs its attribute in front.
  def refusal_message(user, provider)
    error = user.errors.first

    return I18n.t("#{provider}_sign_in_failed") unless error

    error.type == :taken ? error.full_message : error.message
  end

  # Which provider a *failed* request phase belonged to. OmniAuth records the
  # strategy on the environment when it fails, so the message names the button
  # the person actually pressed rather than always naming Google. Google is
  # the fallback, so an unknown strategy still produces a real sentence.
  def failed_provider
    strategy = request.env['omniauth.error.strategy']&.name.to_s

    strategy == RegistrationGateMiddleware::APPLE_PROVIDER ? APPLE : GOOGLE
  end

  # The one request in this app that arrives with no authenticity token and
  # has to be honoured anyway: Apple's form_post from appleid.apple.com,
  # whether it carries a person or a refusal.
  def apple_callback_post?
    request.post? && request.path == user_apple_omniauth_callback_path
  end

  def refuse(message)
    redirect_to new_user_session_path, alert: message, status: :see_other
  end
end
