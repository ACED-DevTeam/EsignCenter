# frozen_string_literal: true

# Self-serve sign-up rules shared by the email+password path
# (RegistrationsController) and the Google path (OmniauthCallbacksController):
# who may create an account, and what that account looks like. See
# docs/signup.md.
module Registrations
  module_function

  # Both credentials, or no Google: with only the id the button would render
  # and the exchange with Google would fail after the bounce.
  def google_enabled?
    Docuseal.registration_enabled? &&
      ENV['GOOGLE_OAUTH_CLIENT_ID'].present? && ENV['GOOGLE_OAUTH_CLIENT_SECRET'].present?
  end

  # Per-IP sign-up velocity (the two registration rows of Quotas::Limits).
  # Redis-backed like every other velocity limit (fails open when Redis is
  # down — availability over a throttle). Raises RateLimit::LimitApproached.
  def assert_ip_allowed!(remote_ip)
    RateLimit.call("signup-ip-hour-#{remote_ip}", limit: Quotas::Limits::SIGNUPS_PER_IP_PER_HOUR, ttl: 1.hour)
    RateLimit.call("signup-ip-day-#{remote_ip}", limit: Quotas::Limits::SIGNUPS_PER_IP_PER_DAY, ttl: 1.day)
  end

  # Per-IP sign-up ATTEMPT ceiling, a different thing from the budget above:
  # it counts every try, spent before the work an attempt costs us rather
  # than after a success. The sign-up form's first act is an outbound call to
  # Cloudflare with a five-second timeout, so a stranger replaying POSTs with
  # a junk token ties up one web thread per request for free — a few dozen
  # parallel connections and the app answers nobody. This is checked first,
  # before that call is made. Same fail-open-on-Redis-down behaviour as every
  # other velocity limit. Raises RateLimit::LimitApproached.
  def assert_ip_attempt_allowed!(remote_ip)
    RateLimit.call("signup-attempt-ip-hour-#{remote_ip}",
                   limit: Quotas::Limits::SIGNUP_ATTEMPTS_PER_IP_PER_HOUR, ttl: 1.hour)
  end

  # The same ceiling for the OmniAuth endpoints, counted separately because
  # one Google sign-in is two requests (authorize, then callback) and because
  # its cost is Google's token exchange, not Cloudflare's. Checked in
  # RegistrationGateMiddleware: OmniAuth's own middleware makes that outbound
  # call before any controller of ours runs, so nothing at the controller
  # level can protect this door.
  def assert_oauth_attempt_allowed!(remote_ip)
    RateLimit.call("oauth-attempt-ip-hour-#{remote_ip}",
                   limit: Quotas::Limits::OAUTH_ATTEMPTS_PER_IP_PER_HOUR, ttl: 1.hour)
  end

  # The domain list only, never the MX lookup: no DNS on the request path.
  def disposable_email?(email)
    return false if email.blank?

    ValidEmail2::Address.new(email.to_s).disposable_domain?
  end

  # Saving a sign-up: the user save is what writes everything (belongs_to
  # autosaves the new account first), so a validation failure — taken email,
  # short password, disposable address — writes nothing. Two sign-ups for one
  # address at the same moment: the loser hits the unique index instead of
  # the validation, and is told the same thing instead of a 500. Both sign-up
  # doors save through here.
  # `source` names which door this is (LegalAcceptance::SOURCES) and is what
  # turns on the legal acceptance: the Terms and Privacy rows are written in
  # the SAME transaction as the user, so a sign-up that fails afterwards can
  # never leave an agreement behind for a person who does not exist — and,
  # just as important, a person can never exist without one. A failure to
  # record the agreement is therefore a failure to sign up, and is raised
  # rather than swallowed.
  #
  # REQUIRED rather than defaulted (review 2), because the default was the
  # dangerous one: a door added next year that simply forgot the argument
  # would create a login with no agreement behind it and nothing would say
  # so. Now it has to answer the question. A headless caller with no human in
  # front of it — a console, a provisioning script — passes `source: nil`
  # explicitly, which records nothing and is a decision somebody made rather
  # than one they overlooked.
  def save_signup(user, source:, request: nil, versions: nil)
    saved = false

    User.transaction do
      saved = user.save(context: :registration)

      LegalDocuments.record_acceptance!(user, request:, source:, versions:) if saved && source
    end

    # The four starter templates (D50). Enqueued HERE, from the one place both
    # self-serve doors save through, so the email form and the Google button
    # seed by construction rather than because each remembered to. Never for
    # anything else: only an account that was created by this very save gets
    # them, which is what keeps an invitee joining an existing account — and
    # any headless caller reusing this method later — out of it.
    # StarterTemplatesJob holds its own enqueue until this transaction has
    # committed, and swallows and reports its own failures: nobody's sign-up
    # fails because a sample document did.
    if saved && user.account.customer? && user.account.previously_new_record?
      StarterTemplatesJob.perform_later(user.account_id)
    end

    saved
  rescue ActiveRecord::RecordNotUnique
    user.errors.add(:email, :taken)

    false
  end

  # A brand-new customer account for a stranger, with its admin user
  # (unbuilt, unsaved): the person's name is the account name until they
  # change it in Settings, the timezone is what their browser reported, the
  # language is the one the sign-up page rendered in. The user is unconfirmed
  # — the email path leaves it so; the Google path confirms it itself.
  def build_signup(name:, email:, password:, timezone:, locale: I18n.locale)
    name = name.to_s.strip
    email = email.to_s.strip
    first_name, last_name = name.split(/\s+/, 2)

    account = Account.new(
      name: name.presence || email,
      timezone: Accounts.normalize_timezone(timezone.presence || 'UTC'),
      locale: account_locale_for(locale),
      account_kind: Account::CUSTOMER_KIND
    )

    account.users.new(email:, password:, first_name:, last_name:, role: User::ADMIN_ROLE)
  end

  # Account locales are the region-tagged set the account settings page
  # offers; the browser locale is matched by language and falls back to
  # US English.
  def account_locale_for(locale)
    options = AccountsController::LOCALE_OPTIONS.keys
    locale = locale.to_s

    options.find { |option| option == locale } ||
      options.find { |option| option.split('-').first == locale.split('-').first } ||
      'en-US'
  end
end
