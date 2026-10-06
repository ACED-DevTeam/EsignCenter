# frozen_string_literal: true

# Secret-safe checks for the configuration a dark production deploy needs.
# The checks only report variable names and expected shapes; they never return
# or print credential values.
require 'uri'

module ProductionReadiness
  Check = Data.define(:name, :ok, :message)

  module_function

  def checks(env = ENV)
    [
      present_check(env, 'DATABASE_URL'),
      present_check(env, 'SECRET_KEY_BASE'),
      app_origin_check(env),
      exact_check(env, 'FORCE_SSL', 'true'),
      admin_provision_token_check(env),
      timestamp_server_check(env),
      present_check(env, 'SMTP_ADDRESS'),
      present_check(env, 'SMTP_FROM'),
      smtp_credentials_check(env),
      smtp_encryption_check(env),
      smtp_certificate_check(env),
      email_delivery_mode_check(env),
      storage_backend_check(env),
      launch_switch_check(env, 'REGISTRATION_ENABLED'),
      launch_switch_check(env, 'BILLING_ENABLED')
    ]
  end

  def failures(env = ENV)
    checks(env).reject(&:ok)
  end

  def check_boot!(env = ENV)
    return unless Rails.env.production?

    failures = [exact_check(env, 'FORCE_SSL', 'true'), app_origin_check(env),
                admin_provision_token_check(env), timestamp_server_check(env),
                storage_backend_check(env)].reject(&:ok)

    raise failures.map(&:message).join('; ') if failures.any?
  end

  def present_check(env, name)
    present = !env[name].to_s.strip.empty?

    Check.new(name:, ok: present, message: present ? "#{name} is set" : "#{name} is not set")
  end

  def exact_check(env, name, expected)
    matches = env[name] == expected
    message = matches ? "#{name} is #{expected}" : "#{name} must be exactly #{expected}"

    Check.new(name:, ok: matches, message:)
  end

  def smtp_credentials_check(env = ENV)
    pair_present = %w[SMTP_USERNAME SMTP_PASSWORD].all? { |name| !env[name].to_s.strip.empty? }
    postmark_token_present = !env['POSTMARK_API_TOKEN'].to_s.strip.empty?
    ok = pair_present || postmark_token_present
    message = if ok
                'SMTP authentication is configured'
              else
                'SMTP authentication requires SMTP_USERNAME and SMTP_PASSWORD, or POSTMARK_API_TOKEN'
              end

    Check.new(name: 'SMTP_CREDENTIALS', ok:, message:)
  end

  def app_origin_check(env = ENV)
    app_url = env['APP_URL'].to_s.strip

    return present_check(env, 'HOST') if app_url.empty?

    uri = URI.parse(app_url)
    valid = uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil? &&
            ['', '/'].include?(uri.path) && uri.query.nil? && uri.fragment.nil?
    message = if valid
                'APP_URL is an absolute HTTPS origin'
              else
                'APP_URL must be an absolute HTTPS origin with no credentials, path, query, or fragment'
              end

    Check.new(name: 'APP_URL', ok: valid, message:)
  rescue URI::InvalidURIError
    Check.new(name: 'APP_URL', ok: false,
              message: 'APP_URL must be an absolute HTTPS origin with no credentials, path, query, or fragment')
  end

  def admin_provision_token_check(env = ENV)
    token = env['ADMIN_PROVISION_TOKEN'].to_s
    ok = !token.strip.empty? && !token.start_with?('dev_prov_')
    message = if ok
                'ADMIN_PROVISION_TOKEN is set and is not the development placeholder'
              else
                'ADMIN_PROVISION_TOKEN is missing or uses the public dev_prov_ placeholder'
              end

    Check.new(name: 'ADMIN_PROVISION_TOKEN', ok:, message:)
  end

  def timestamp_server_check(env = ENV)
    urls = env['TIMESERVER_URL'].to_s.split(',').map(&:strip)
    valid = urls.any? && urls.none?(&:empty?) && urls.all? do |url|
      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) && uri.host && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end
    message = if valid
                'TIMESERVER_URL contains absolute HTTP(S) endpoint(s)'
              else
                'TIMESERVER_URL must contain absolute HTTP(S) endpoint(s), separated by commas'
              end

    Check.new(name: 'TIMESERVER_URL', ok: valid, message:)
  end

  def email_delivery_mode_check(env = ENV)
    mode = env['EMAIL_DELIVERY_MODE'].to_s
    ok = mode.empty? || mode == 'smtp'
    message = if ok
                'EMAIL_DELIVERY_MODE uses production SMTP'
              else
                'EMAIL_DELIVERY_MODE must be unset or smtp for production'
              end

    Check.new(name: 'EMAIL_DELIVERY_MODE', ok:, message:)
  end

  def smtp_encryption_check(env = ENV)
    starttls_enabled = env['SMTP_ENABLE_STARTTLS'] != 'false'
    direct_tls_enabled = env['SMTP_ENABLE_SSL'] == 'true' || env['SMTP_ENABLE_TLS'] == 'true'
    ok = starttls_enabled || direct_tls_enabled
    message = if ok
                'Platform SMTP transport encryption is enabled'
              else
                'Platform SMTP requires STARTTLS, SSL, or TLS in production'
              end

    Check.new(name: 'SMTP_TRANSPORT_ENCRYPTION', ok:, message:)
  end

  def smtp_certificate_check(env = ENV)
    ok = env['SMTP_SSL_VERIFY'] != 'false'
    message = if ok
                'Platform SMTP certificate verification is enabled'
              else
                'SMTP_SSL_VERIFY=false is not allowed for the production platform server'
              end

    Check.new(name: 'SMTP_CERTIFICATE_VERIFICATION', ok:, message:)
  end

  # Render wipes the container disk on every deploy, so production stores
  # files in a bucket. Local disk is allowed only when somebody says so out
  # loud (a local production preview, a host with a mounted persistent disk).
  # The database half of the storage check (existing files and a legacy
  # settings row) runs after boot in StorageConfigGuard.
  STORAGE_ENV_KEYS = %w[S3_ATTACHMENTS_BUCKET GCS_BUCKET AZURE_CONTAINER].freeze
  LOCAL_DISK_OPT_IN = 'ALLOW_LOCAL_DISK_STORAGE'

  def storage_backend_check(env = ENV)
    bucket = STORAGE_ENV_KEYS.find { |name| !env[name].to_s.strip.empty? }
    ok = !bucket.nil? || env[LOCAL_DISK_OPT_IN] == 'true'
    message = if bucket
                "File storage uses #{bucket}"
              elsif ok
                "File storage uses the local disk (#{LOCAL_DISK_OPT_IN}=true)"
              else
                "File storage needs one of #{STORAGE_ENV_KEYS.join(', ')} " \
                  "(or #{LOCAL_DISK_OPT_IN}=true for a persistent local disk)"
              end

    Check.new(name: 'FILE_STORAGE', ok:, message:)
  end

  def launch_switch_check(env, name)
    disabled = env[name] != 'true'
    message = disabled ? "#{name} is off" : "#{name} must stay off for the dark deploy"

    Check.new(name:, ok: disabled, message:)
  end
end
