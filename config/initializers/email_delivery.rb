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

    if ENV['SMTP_FROM'].blank? && ENV['SMTP_ADDRESS'].present?
      message = 'SMTP_ADDRESS is set but SMTP_FROM is not; platform mail would go out under tenant From addresses'

      raise message if Rails.env.production?

      Rails.logger.warn(message)
    end

    return unless ENV.values_at('SMTP_USERNAME', 'SMTP_PASSWORD', 'POSTMARK_API_TOKEN').all?(&:blank?)

    Rails.logger.warn('SMTP credentials are not set; the platform SMTP connection will be unauthenticated')
  end
end

EmailDeliveryConfig.check!

# A transport that drops the message (see lib/null_mail_delivery.rb).
ActiveSupport.on_load(:action_mailer) do
  add_delivery_method :null, NullMailDelivery
end
