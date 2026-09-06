# frozen_string_literal: true

# Self-serve sign-up rules shared by the email+password path
# (RegistrationsController) and the two OmniAuth paths, Google and Apple
# (OmniauthCallbacksController): who may create an account, and what that
# account looks like. See docs/signup.md.
module Registrations
  # The three doors a human can walk through. `LegalAcceptance::SOURCES` also
  # holds INVITE, which joins an account somebody else already owns.
  SELF_SERVE_SOURCES = [LegalAcceptance::SIGNUP_EMAIL, LegalAcceptance::SIGNUP_GOOGLE,
                        LegalAcceptance::SIGNUP_APPLE].freeze

  # Apple signs its own client secret, so there is no "secret" slot: the four
  # values are the Service ID, the Apple Developer team, the key's id and the
  # .p8 private key that signs the short-lived JWT sent in the secret's place.
  APPLE_KEYS = %w[APPLE_OAUTH_CLIENT_ID APPLE_OAUTH_TEAM_ID APPLE_OAUTH_KEY_ID APPLE_OAUTH_PRIVATE_KEY].freeze

  # The env file ships every credential slot pre-written with a `PASTE_...`
  # marker so nobody has to remember which ones exist. A slot still carrying
  # its marker is not a credential, and treating it as one would put a button
  # on the sign-in page that cannot work.
  PLACEHOLDER_PREFIX = 'PASTE_'

  module_function

  # Both credentials, or no Google: with only the id the button would render
  # and the exchange with Google would fail after the bounce.
  def google_enabled?
    Docuseal.registration_enabled? &&
      ENV['GOOGLE_OAUTH_CLIENT_ID'].present? && ENV['GOOGLE_OAUTH_CLIENT_SECRET'].present?
  end

  # All four, or no Apple — the same all-or-nothing rule Google gets, for the
  # same reason. Two of the four have a shape Apple documents and never
  # varies (the team id and the key id are ten characters), and the fourth
  # has to be a private key or the strategy cannot sign anything, so those
  # are checked rather than assumed: a half-filled slot hides the button
  # instead of offering a sign-in that ends in an error page.
  def apple_enabled?
    Docuseal.registration_enabled? && apple_configured?
  end

  def apple_configured?
    APPLE_KEYS.all? { |key| configured?(ENV.fetch(key, nil)) } &&
      apple_id_format?(ENV.fetch('APPLE_OAUTH_TEAM_ID', nil)) &&
      apple_id_format?(ENV.fetch('APPLE_OAUTH_KEY_ID', nil)) &&
      apple_private_key.include?('PRIVATE KEY')
  end

  # A value that is present and is not still the env file's paste marker.
  def configured?(value)
    value.present? && !value.to_s.start_with?(PLACEHOLDER_PREFIX)
  end

  # Apple team ids and key ids are ten alphanumeric characters, always.
  def apple_id_format?(value)
    value.to_s.match?(/\A[A-Za-z0-9]{10}\z/)
  end

  # A .p8 key is several lines; a host's environment editor usually stores it
  # as one line with the breaks escaped, so both spellings are accepted here
  # rather than in four different places later.
  def apple_private_key
    ENV.fetch('APPLE_OAUTH_PRIVATE_KEY', '').to_s.gsub('\\n', "\n")
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

    seed_starter_templates(user, source) if saved

    saved
  rescue ActiveRecord::RecordNotUnique
    user.errors.add(:email, :taken)

    false
  end

  # The four starter templates (D50). Enqueued HERE, from the one place every
  # self-serve door saves through, so the email form and both sign-in buttons
  # seed by construction rather than because each remembered to.
  #
  # Three conditions, and all three are about the SAME question — is this a
  # stranger's brand-new account, created by a human at a sign-up page?
  #
  #   * `source` is one of the self-serve doors. A headless caller passes
  #     `source: nil` (a console, a provisioning script), and a script that
  #     creates a customer account is not a person who needs four sample
  #     documents to look at;
  #   * the account is a customer one, not internal, operator or testing;
  #   * this very save created it, which keeps an invitee joining an account
  #     that already exists out of it.
  #
  # StarterTemplatesJob holds its own enqueue until the sign-up transaction has
  # committed and swallows its own failures once it runs — but a queue that is
  # DOWN fails at the enqueue, out here, where the account already exists and
  # the person is mid-sign-up. Nobody's sign-up fails because a sample document
  # did, so that failure is reported and dropped too.
  def seed_starter_templates(user, source)
    return unless SELF_SERVE_SOURCES.include?(source)
    return unless user.account.customer? && user.account.previously_new_record?

    StarterTemplatesJob.perform_later(user.account_id)
  rescue StandardError => e
    ErrorReport.error(e, account_id: user.account_id)
  end

  # A brand-new customer account for a stranger, with its admin user
  # (unbuilt, unsaved): the person's name is the account name until they
  # change it in Settings, the timezone is what their browser reported, the
  # language is the one the sign-up page rendered in. The user is unconfirmed
  # — the email path leaves it so; the Google and Apple paths confirm it
  # themselves.
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
