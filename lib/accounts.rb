# frozen_string_literal: true

module Accounts
  LINK_EXPIRES_AT = ENV.fetch('FILE_URLS_EXPIRE_MINUTES', '40').to_i.minutes

  class MissingEsignCertsError < StandardError; end

  # Raised by with_last_admin_guard when the change it is wrapping would leave
  # an account with nobody who can administer it. Every door that can reach it
  # turns it back into the same sentence the check used to print
  # (`last_admin_cannot_be_removed`).
  class LastAdminError < StandardError; end

  module_function

  def create_duplicate(account)
    new_account = account.dup
    new_account.account_kind = account.account_kind

    new_user = account.users.first.dup

    new_user.uuid = SecureRandom.uuid
    new_user.account = new_account
    new_user.encrypted_password = SecureRandom.hex
    new_user.email = "#{SecureRandom.hex}@esigncenter.invalid"
    new_user.confirmed_at = Time.current

    account.templates.each do |template|
      new_template = template.dup

      new_template.account = new_account
      new_template.slug = SecureRandom.base58(14)

      new_template.archived_at = nil
      new_template.save!

      Templates::CloneAttachments.call(template: new_template, original_template: template)
    end

    new_user.save!(validate: false)
    new_account.templates.update_all(folder_id: new_account.default_template_folder.id)

    new_account
  end

  # SEAT OCCUPANCY: how many of this account's seats are taken right now.
  #
  # Three kinds of row take a seat and one kind does not:
  #   * an active person in the account (and in its non-testing linked
  #     children — a testing child is the same tenant and is never billed);
  #   * a pending invitation, because on a paid account the seat was BOUGHT
  #     before the invitation went out and must stay held until the person
  #     arrives or the invitation lapses;
  #   * never an integration (API-only) user, and never a READ-ONLY member —
  #     a member who lost their seat in a downgrade is still in the account,
  #     which is exactly why "one seat, four people" is a state we can sit in.
  def seat_occupancy(account)
    ids = seat_account_ids(account)

    seat_holders(ids).count + AccountInvite.pending.where(account_id: ids).count
  end

  # The people who take a seat, as a scope: one definition of "seat-holding
  # member" for every question that asks it (occupancy, who a downgrade keeps,
  # who a downgrade parks). Takes account ids so a caller that has already
  # resolved the family does not resolve it twice.
  def seat_holders(account_ids)
    User.where(account_id: account_ids).where.not(role: :integration).active.full_access
  end

  # The old name, kept because half the app (and the quota engine) asks the
  # question this way. One answer, one implementation.
  def users_count(account)
    seat_occupancy(account)
  end

  # The accounts whose people share this account's seats: itself plus every
  # non-testing linked child that has not been archived.
  def seat_account_ids(account)
    linked_ids = account.account_linked_accounts.where.not(account_type: :testing).pluck(:linked_account_id)
    archived_ids = account.linked_accounts.where.not(archived_at: nil).ids

    ([account.id] + linked_ids - archived_ids).uniq
  end

  # Is this the last person who can administer the account? Nobody may remove,
  # archive, demote, make read-only or move away the last ACTIVE, full-access
  # admin: an account with no administrator can never invite anyone, change a
  # role or fix its own billing again.
  #
  # Asked about the user's OWN account, not the billing account: every account
  # needs an administrator of its own.
  # `account_id` is which account is being asked about — the user's own by
  # default, and the account they are LEAVING when a request is moving them
  # somewhere else (UsersController#update).
  def last_admin?(user, account_id: user&.account_id)
    return false if user.nil? || !user.admin? || user.archived_at? || user.read_only?

    !User.where(account_id:).where.not(id: user.id)
         .admins.active.full_access.exists?
  end

  # The guard the answer above is only half of.
  #
  # `last_admin?` is a READ, and on its own it promises nothing: between the
  # read and the write that follows it, another request can archive, demote or
  # park the OTHER administrator. With exactly two administrators that is a
  # race either of them can lose — each asks "is there a second one?", each is
  # told yes, and each then writes to a DIFFERENT user row, so no unique index
  # and no validation stands in the way. The account comes out of it with
  # nobody who can invite anyone, change a role or fix its own billing, and
  # only an operator can put it back.
  #
  # So every door that can take administrator capability away — archiving
  # somebody (UsersController#destroy), demoting or moving them
  # (UsersController#update), and handing their seat back
  # (UsersReadOnlyController#create) — runs its write in here instead. The
  # ACCOUNT row is locked first (the same `with_lock` the rest of the app
  # serialises account-level decisions with), the question is asked again on
  # the far side of that lock, and the mutation is committed inside it.
  # Postgres then serialises the two requests: the first one wins, the second
  # one waits, re-reads, finds itself holding the last administrator and is
  # refused by the sentence it would have been refused by anyway.
  #
  # `account_id` is the account that can be STRANDED: the user's own, and the
  # one they are leaving when the change is a move. `user`'s own in-memory
  # state is deliberately not reloaded — UsersController#update has already
  # assigned the destination account to it by the time it asks, and the
  # question this has to answer is about the account being left.
  #
  # LOCK ORDER. One order is obeyed by every path in the application that can
  # change who holds a seat, and it is written out in full in
  # BillingLifecycle.park_everyone_but_one_admin!:
  #
  #     account_subscriptions row  →  accounts row  →  Quotas advisory lock
  #
  # This guard is the middle of it. The seat check inside the block takes
  # Quotas' advisory creation lock, so the order here is always account row →
  # advisory lock and never the other way round; and the callers hand the
  # seat back to Stripe — the one thing that would take the subscription row
  # — only AFTER this block has returned and the account row is free again.
  # There is therefore nothing here to deadlock against, including the
  # automatic downgrade, which arrives holding the subscription row and takes
  # this same account row inside it.
  def with_last_admin_guard(user, account_id: user&.account_id)
    account = Account.find_by(id: account_id)

    # No account to strand (a user row without one, or a caller that passed
    # nothing): there is nothing for this guard to protect.
    return yield if account.nil?

    account.with_lock do
      raise LastAdminError if last_admin?(user, account_id:)

      yield
    end
  end

  def find_or_create_testing_user(account)
    user = User.where(role: :admin).order(:id).find_by(account: account.testing_accounts)

    return user if user

    testing_account = account.dup.tap { |a| a.name = "Testing - #{a.name}" }
    testing_account.uuid = SecureRandom.uuid
    testing_account.account_kind = account.account_kind

    ApplicationRecord.transaction do
      account.testing_accounts << testing_account

      original_email = account.users.order(:id).first.email
      test_email = generate_unique_test_email(original_email)

      testing_user = testing_account.users.new(
        email: test_email,
        first_name: 'Testing',
        last_name: 'Environment',
        password: SecureRandom.hex,
        role: :admin
      )
      testing_user.skip_confirmation!
      testing_user.save!
      testing_user
    end
  end

  def generate_unique_test_email(original_email)
    base_email = original_email.sub('@', '+test@')

    return base_email unless User.exists?(email: base_email)

    (1..3).each do |i|
      test_email = original_email.sub('@', "+test#{i}@")

      return test_email unless User.exists?(email: test_email)
    end

    timestamp = Time.current.to_i

    original_email.sub('@', "+test#{timestamp}@")
  end

  def load_recipient_form_fields(_account)
    []
  end

  # Signing identity by account kind (Session 4):
  #   customer  — always the platform certificate, even when the account owns
  #               an esign_certs row (legacy backfill or provisioning); testing
  #               children copy the kind, so they follow the same rule.
  #   internal  — its own row (self, then a testing parent), never the platform
  #               certificate; a missing row is an error.
  #   operator  — its own row when it has one, otherwise the platform one.
  def load_signing_pkcs(account)
    return PlatformCertificate.pkcs if account.customer?

    encrypted_config = esign_certs_config_for(account)

    return PlatformCertificate.pkcs if encrypted_config.nil? && account.operator?

    raise_missing_esign_certs!(account) unless encrypted_config

    cert_data = encrypted_config.value
    default_cert = cert_data['custom']&.find { |e| e['status'] == 'default' && e['data'].present? }

    if default_cert
      OpenSSL::PKCS12.new(Base64.urlsafe_decode64(default_cert['data']), default_cert['password'].to_s)
    else
      GenerateCertificate.load_pkcs(cert_data)
    end
  end

  # Own row, then a testing parent's row (Account#configuration_lookup_accounts,
  # the same walk certs, account configs and SMTP pins use), then the
  # environment value. Customer accounts never carry their own timestamp
  # server: the platform picks the TSA for them.
  def load_timeserver_url(account)
    return Docuseal::TIMESERVER_URL.presence if account.customer?

    account.configuration_lookup_accounts.each do |source_account|
      url = source_account.encrypted_configs.find_by(key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY)&.value.presence

      return url if url
    end

    Docuseal::TIMESERVER_URL.presence
  end

  # What a signature from this account should be checked against: the platform
  # chain and every retired platform chain (every customer signs with it),
  # plus this account's own chain when it is an internal/operator account
  # that owns one, plus the TRUSTED_CERTS environment chain. A customer
  # without a row is not an error here. Never generates the platform key.
  def load_trusted_certs(account)
    encrypted_config = esign_certs_config_for(account) unless account.customer?

    [*platform_chains,
     *config_trusted_certs(encrypted_config&.value),
     *Docuseal.trusted_certs]
  end

  # Everything the public verify page may trust when checking a signature's
  # chain: our own signer certificates (platform_signer_certs) plus
  # TRUSTED_CERTS. The environment certificates help build a chain but never
  # make a signature "ours" — that is platform_signer_certs' job.
  def platform_verification_certs
    [*platform_signer_certs, *Docuseal.trusted_certs]
  end

  # The certificates a signature must have been made with to count as an
  # EsignCenter signature: the current and every retired platform chain, and
  # every internal and operator account's own chain (documents signed before
  # the platform certificate existed, and internal accounts today). Account
  # rows are cached for 5 minutes — they change by hand. Never generates.
  def platform_signer_certs
    pems = Rails.cache.fetch('platform_verification_certs', expires_in: 5.minutes) do
      account_certs_pems
    end

    [*platform_chains, *pems.map { |pem| OpenSSL::X509::Certificate.new(pem) }]
  end

  def platform_chains
    [*PlatformCertificate.current_chain, *PlatformCertificate.retired_chains]
  end

  # One unreadable row (a corrupt custom PKCS#12, a bad password, a value
  # encrypted under a key this deployment no longer has) is reported and
  # skipped: it must not take verification down for every other account.
  def account_certs_pems
    accounts = Account.where(account_kind: [Account::INTERNAL_KIND, Account::OPERATOR_KIND])

    EncryptedConfig.where(account: accounts, key: EncryptedConfig::ESIGN_CERTS_KEY).flat_map do |config|
      config_trusted_certs(config.value).map(&:to_pem)
    rescue OpenSSL::OpenSSLError, ArgumentError, ActiveRecord::Encryption::Errors::Base => e
      ErrorReport.error(e, account_id: config.account_id, key: config.key)

      []
    end
  end

  # The certificates a stored esign_certs value vouches for: the row's own
  # chain and every custom PKCS#12 certificate it carries.
  def config_trusted_certs(cert_data)
    return [] if cert_data.blank?

    default_pkcs = GenerateCertificate.load_pkcs(cert_data) if cert_data['cert'].present?

    custom_certs = cert_data.fetch('custom', []).filter_map do |e|
      next if e['data'].blank?

      OpenSSL::PKCS12.new(Base64.urlsafe_decode64(e['data']), e['password'].to_s)
    end

    [*(default_pkcs && [default_pkcs.certificate, *default_pkcs.ca_certs]),
     *custom_certs.map(&:certificate),
     *custom_certs.flat_map(&:ca_certs).compact]
  end

  def can_send_emails?(account, **_params)
    return true if Rails.env.development?

    # Mirrors MailConfigs.resolve so the UI never promises mail the
    # interceptor would drop (e.g. an incomplete pinned config).
    MailConfigs.resolve(account).source != :none
  end

  def can_send_invitation_emails?(_account)
    true
  end

  # The remove_branding flag counts only while the account is entitled to
  # branding removal: a downgraded account's flag stays in place but goes
  # inert (D43 — a downgrade never purges), and no account means branding on.
  def branding_removed?(account)
    return false if account.nil?
    return false unless Entitlements.allowed?(account, :branding_removal)

    AccountConfigs.find_for_account(account, AccountConfig::REMOVE_BRANDING_KEY)&.value == true
  end

  # Custom email copy is a paid-only row read at send time: an account-level
  # email template or a per-template email key saved while paid stays in
  # place after a downgrade (D43) but the default copy renders until the
  # account is entitled again. Both readers return nil for an unentitled account.
  def custom_email_config(account, key)
    return nil unless Entitlements.allowed?(account, :custom_email_templates)

    AccountConfigs.find_for_account(account, key)
  end

  def custom_email_copy(account, preferences, key)
    return nil unless Entitlements.allowed?(account, :custom_email_templates)

    preferences&.dig(key).presence
  end

  def normalize_timezone(timezone)
    tzinfo = TZInfo::Timezone.get(ActiveSupport::TimeZone::MAPPING[timezone] || timezone)

    ::ActiveSupport::TimeZone.all.find { |e| e.tzinfo == tzinfo }&.name || timezone
  rescue TZInfo::InvalidTimezoneIdentifier
    'UTC'
  end

  def link_expires_at(account)
    return if AccountConfig.find_or_initialize_by(account: account,
                                                  key: AccountConfig::DOWNLOAD_LINKS_EXPIRE_KEY).value == false

    LINK_EXPIRES_AT.from_now
  end

  def esign_certs_config_for(account)
    account.configuration_lookup_accounts.each do |source_account|
      encrypted_config = source_account.encrypted_configs.find_by(key: EncryptedConfig::ESIGN_CERTS_KEY)

      return encrypted_config if encrypted_config
    end

    nil
  end

  def raise_missing_esign_certs!(account)
    raise MissingEsignCertsError, "Account #{account.id} has no e-sign certificates configured"
  end
end
