# frozen_string_literal: true

module Accounts
  LINK_EXPIRES_AT = ENV.fetch('FILE_URLS_EXPIRE_MINUTES', '40').to_i.minutes

  class MissingEsignCertsError < StandardError; end

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

  def users_count(account)
    rel = User.where(account_id: account.id).or(
      User.where(account_id: account.account_linked_accounts
                                           .where.not(account_type: :testing)
                                           .select(:linked_account_id))
    )

    rel.where.not(account: account.linked_accounts.where.not(archived_at: nil))
       .where.not(role: :integration).active.count
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
