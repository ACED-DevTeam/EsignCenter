# frozen_string_literal: true

module MailConfigs
  Result = Struct.new(:source, :smtp, :from, :account)

  OPEN_TIMEOUT = ENV.fetch('SMTP_OPEN_TIMEOUT', '15').to_i
  READ_TIMEOUT = ENV.fetch('SMTP_READ_TIMEOUT', '25').to_i

  module_function

  def resolve(account, platform: false)
    source_account, email_config = find_smtp_config(account) unless platform

    if email_config
      Result.new(
        source: :account,
        account: source_account,
        smtp: build_account_smtp(email_config.value),
        from: %("#{source_account.name.to_s.delete('"')}" <#{email_config.value['from_email']}>)
      )
    elsif ENV['SMTP_ADDRESS'].present?
      Result.new(source: :env, smtp: build_env_smtp, from: ENV['SMTP_FROM'].presence)
    else
      Result.new(source: :none, smtp: {}, from: nil)
    end
  end

  # Returns [account_the_pin_belongs_to, config] or [nil, nil].
  #
  # Testing accounts are created by duplication without configs, so — like
  # esign certs (Accounts.esign_certs_config_for) and account configs
  # (AccountConfigs.find_for_account) — a test-mode child falls back to its
  # parent's pinned SMTP server instead of dropping to the platform default.
  #
  # Per-account SMTP is a paid-only row: an unentitled account's pin stays in
  # place (D43) but is skipped, so mail falls through to the platform default
  # exactly as for an unpinned account. A testing child resolves its plan
  # through its parent, so it keeps inheriting the parent's pin.
  def find_smtp_config(account)
    return [nil, nil] unless account
    return [nil, nil] unless Entitlements.allowed?(account, :account_smtp)

    account.configuration_lookup_accounts.each do |source_account|
      config = usable_smtp_config(source_account)

      return [source_account, config] if config
    end

    [nil, nil]
  end

  # An incomplete pin (the settings form can save an empty hash) must not
  # shadow the platform default and silently kill the tenant's mail.
  def usable_smtp_config(account)
    config = EncryptedConfig.find_by(account:, key: EncryptedConfig::EMAIL_SMTP_KEY)

    config if config && pin_usable?(config.value)
  end

  def delivery_mode
    mode = ENV.fetch('EMAIL_DELIVERY_MODE', nil)

    return mode if mode.in?(%w[smtp test])

    Rails.env.production? ? 'smtp' : 'test'
  end

  def pin_usable?(value)
    value.is_a?(Hash) && value['host'].present? && value['from_email'].present?
  end

  def build_account_smtp(value)
    is_tls = value['security'] == 'tls' || (value['security'].blank? && value['port'].to_s == '465')
    is_ssl = value['security'] == 'ssl'
    is_noverify = value['security'] == 'noverify'

    enable_starttls = is_noverify ? :enable_starttls_auto : :enable_starttls

    {
      user_name: value['username'],
      password: value['password'],
      address: value['host'],
      port: value['port'],
      domain: value['domain'],
      openssl_verify_mode: is_noverify ? OpenSSL::SSL::VERIFY_NONE : nil,
      authentication: value['password'].present? ? value.fetch('authentication', 'plain') : nil,
      enable_starttls => !is_tls && !is_ssl,
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT,
      ssl: is_ssl,
      tls: is_tls
    }.compact_blank
  end

  def build_env_smtp
    password = ENV['SMTP_PASSWORD'].presence || ENV['POSTMARK_API_TOKEN'].presence

    {
      address: ENV.fetch('SMTP_ADDRESS', nil),
      port: ENV.fetch('SMTP_PORT', '587'),
      domain: ENV['SMTP_DOMAIN'].presence,
      user_name: ENV['SMTP_USERNAME'].presence || ENV['POSTMARK_API_TOKEN'].presence,
      password:,
      openssl_verify_mode: ENV['SMTP_SSL_VERIFY'] == 'false' ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER,
      authentication: password.present? ? ENV.fetch('SMTP_AUTHENTICATION', 'plain') : nil,
      enable_starttls: ENV['SMTP_ENABLE_STARTTLS'] != 'false',
      ssl: ENV['SMTP_ENABLE_SSL'] == 'true',
      tls: ENV['SMTP_ENABLE_TLS'] == 'true',
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT
    }.compact
  end
end
