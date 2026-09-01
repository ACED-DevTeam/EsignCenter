# frozen_string_literal: true

module ActionMailerConfigsInterceptor
  module_function

  def delivering_email(message)
    account_id = message['X-EC-Account-Id']&.value
    message['X-EC-Account-Id'] = nil

    account = Account.find_by(id: account_id) if account_id.present?

    if Docuseal.demo?
      message.delivery_method(:test)

      return message
    end

    unless MailConfigs.delivery_mode == 'smtp'
      # Never let a real SMTP transport survive a non-smtp delivery mode (a
      # production dry run must not email customers); other transports
      # (letter_opener, test) are already safe.
      message.delivery_method(:test) if message.delivery_method.is_a?(Mail::SMTP)

      return message
    end

    result = MailConfigs.resolve(account)

    case result.source
    when :account
      message.delivery_method(:smtp, result.smtp)
      message.from = result.from
    when :env
      message.delivery_method(:smtp, result.smtp)
      rewrite_from(message, result.from) if result.from
    when :none
      message.delivery_method(:test)
      warn_missing_smtp(message, account)
    end

    message
  end

  def rewrite_from(message, smtp_from)
    from = smtp_from.to_s.split(',').sample

    if from.match?(User::FULL_EMAIL_REGEXP)
      message[:from] = message[:from].to_s.sub(User::EMAIL_REGEXP, from)
    else
      message.from = from
    end
  end

  def warn_missing_smtp(message, account)
    return if message.instance_variable_defined?(:@ec_missing_smtp_warned)

    Rails.logger.warn("no SMTP config for account #{account&.id || 'none'}")
    message.instance_variable_set(:@ec_missing_smtp_warned, true)
  end
end
