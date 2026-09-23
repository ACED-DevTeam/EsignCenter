# frozen_string_literal: true

require_relative '../../lib/mail_configs'
require_relative '../../lib/production_readiness'

module EmailDeliveryConfig
  module_function

  def check!
    explicit_mode = ENV.fetch('EMAIL_DELIVERY_MODE', nil)

    check_explicit_mode!(explicit_mode)
    check_production_mode!

    return unless MailConfigs.delivery_mode == 'smtp'

    check_smtp_address!
    check_smtp_from!
    check_smtp_credentials!
    check_smtp_transport_security!
  end

  def check_explicit_mode!(explicit_mode)
    return if explicit_mode.blank? || explicit_mode.in?(%w[smtp test])

    message = "EMAIL_DELIVERY_MODE=#{explicit_mode} is invalid (use 'smtp' or 'test')"

    raise message if Rails.env.production?

    Rails.logger.warn(message)
  end

  def check_production_mode!
    return unless Rails.env.production? && MailConfigs.delivery_mode != 'smtp'

    raise 'Production EMAIL_DELIVERY_MODE must be smtp'
  end

  def check_smtp_address!
    return if ENV['SMTP_ADDRESS'].present?

    message = 'SMTP delivery mode but SMTP_ADDRESS is not set; only accounts with pinned SMTP can send email'

    raise message if Rails.env.production?

    Rails.logger.warn(message)
  end

  def check_smtp_from!
    return unless ENV['SMTP_FROM'].blank? && ENV['SMTP_ADDRESS'].present?

    message = 'SMTP_ADDRESS is set but SMTP_FROM is not; platform mail would go out under tenant From addresses'

    raise message if Rails.env.production?

    Rails.logger.warn(message)
  end

  def check_smtp_credentials!
    credentials_present = ENV.values_at('SMTP_USERNAME', 'SMTP_PASSWORD').all?(&:present?) ||
                          ENV['POSTMARK_API_TOKEN'].present?

    return if credentials_present

    message = 'SMTP credentials are not set; set SMTP_USERNAME and SMTP_PASSWORD, or POSTMARK_API_TOKEN'

    raise message if Rails.env.production?

    Rails.logger.warn(message)
  end

  def check_smtp_transport_security!
    return unless Rails.env.production?

    checks = [ProductionReadiness.smtp_encryption_check, ProductionReadiness.smtp_certificate_check]
    failures = checks.reject(&:ok)

    raise failures.map(&:message).join('; ') if failures.any?
  end
end

EmailDeliveryConfig.check!

# A transport that drops the message (see lib/null_mail_delivery.rb).
ActiveSupport.on_load(:action_mailer) do
  add_delivery_method :null, NullMailDelivery
end
