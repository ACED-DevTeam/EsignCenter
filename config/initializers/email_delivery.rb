# frozen_string_literal: true

require_relative '../../lib/mail_configs'

module EmailDeliveryConfig
  module_function

  def check!
    return unless MailConfigs.delivery_mode == 'smtp'

    if ENV['SMTP_ADDRESS'].blank?
      message = 'EMAIL_DELIVERY_MODE=smtp but SMTP_ADDRESS is not set; only accounts with pinned SMTP can send email'

      raise message if Rails.env.production?

      Rails.logger.warn(message)
    end

    Rails.logger.warn('SMTP_FROM is not set; messages will keep their existing From address') if ENV['SMTP_FROM'].blank?

    return unless ENV.values_at('SMTP_USERNAME', 'SMTP_PASSWORD', 'POSTMARK_API_TOKEN').all?(&:blank?)

    Rails.logger.warn('SMTP credentials are not set; the platform SMTP connection will be unauthenticated')
  end
end

EmailDeliveryConfig.check!
