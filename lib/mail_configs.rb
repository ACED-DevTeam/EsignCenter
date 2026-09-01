# frozen_string_literal: true

module MailConfigs
  Result = Struct.new(:source, :smtp, :from)

  OPEN_TIMEOUT = ENV.fetch('SMTP_OPEN_TIMEOUT', '15').to_i
  READ_TIMEOUT = ENV.fetch('SMTP_READ_TIMEOUT', '25').to_i

  module_function

  def resolve(account)
    email_config = EncryptedConfig.find_by(account:, key: EncryptedConfig::EMAIL_SMTP_KEY) if account

    # An incomplete pin (the settings form can save an empty hash) must not
    # shadow the platform default and silently kill the tenant's mail.
    email_config = nil if email_config && !pin_usable?(email_config.value)

    if email_config
      Result.new(
        source: :account,
        smtp: build_account_smtp(email_config.value),
        from: %("#{account.name.to_s.delete('"')}" <#{email_config.value['from_email']}>)
      )
    elsif ENV['SMTP_ADDRESS'].present?
      Result.new(source: :env, smtp: build_env_smtp, from: ENV['SMTP_FROM'].presence)
    else
      Result.new(source: :none, smtp: {}, from: nil)
    end
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
