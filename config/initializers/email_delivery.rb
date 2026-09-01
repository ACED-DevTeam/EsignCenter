# frozen_string_literal: true

require_relative '../../lib/mail_configs'

module EmailDeliveryConfig
  module_function

  def check!
    explicit_mode = ENV.fetch('EMAIL_DELIVERY_MODE', nil)

    if explicit_mode.present? && !explicit_mode.in?(%w[smtp test])
      message = "EMAIL_DELIVERY_MODE=#{explicit_mode} is invalid (use 'smtp' or 'test')"

      raise message if Rails.env.production?

      Rails.logger.warn(message)
    end

    return unless MailConfigs.delivery_mode == 'smtp'

    if ENV['SMTP_ADDRESS'].blank?
      message = 'SMTP delivery mode but SMTP_ADDRESS is not set; only accounts with pinned SMTP can send email'

      # Raise only when smtp mode was asked for explicitly; a bare production
      # boot (mode defaulted) keeps working for pinned-account-only setups.
      raise message if Rails.env.production? && explicit_mode == 'smtp'

      Rails.logger.warn(message)
    end

    Rails.logger.warn('SMTP_FROM is not set; messages will keep their existing From address') if ENV['SMTP_FROM'].blank?

    return unless ENV.values_at('SMTP_USERNAME', 'SMTP_PASSWORD', 'POSTMARK_API_TOKEN').all?(&:blank?)

    Rails.logger.warn('SMTP credentials are not set; the platform SMTP connection will be unauthenticated')
  end
end

EmailDeliveryConfig.check!
