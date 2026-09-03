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

  # The domain list only, never the MX lookup: no DNS on the request path.
  def disposable_email?(email)
    return false if email.blank?

    ValidEmail2::Address.new(email.to_s).disposable_domain?
  end

  # Saving a sign-up: the DB transaction is the user save (belongs_to
  # autosaves the new account first), so a validation failure — taken email,
  # short password, disposable address — writes nothing. Two sign-ups for one
  # address at the same moment: the loser hits the unique index instead of
  # the validation, and is told the same thing instead of a 500. Both sign-up
  # doors save through here.
  def save_signup(user)
    user.save(context: :registration)
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
