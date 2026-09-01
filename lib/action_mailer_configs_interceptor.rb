# frozen_string_literal: true

module ActionMailerConfigsInterceptor
  module_function

  def delivering_email(message)
    account_id = message['X-EC-Account-Id']&.value
    message['X-EC-Account-Id'] = nil

    account = Account.find_by(id: account_id) if account_id.present?

    if Docuseal.demo?
      message.delivery_method(null_delivery_method)

      return message
    end

    unless MailConfigs.delivery_mode == 'smtp'
      # Never let a real SMTP transport survive a non-smtp delivery mode (a
      # production dry run must not email customers); other transports
      # (letter_opener, test) are already safe.
      message.delivery_method(null_delivery_method) if message.delivery_method.is_a?(Mail::SMTP)

      return message
    end

    result = MailConfigs.resolve(account)

    case result.source
    when :account
      deliver_via_smtp(message, result.smtp)
      message.from = result.from
    when :env
      deliver_via_smtp(message, result.smtp)
      rewrite_from(message, result.from) if result.from
    when :none
      message.delivery_method(null_delivery_method)
      report_missing_smtp(message, account)
    end

    message
  end

  # A failed SMTP send must raise so the Sidekiq mail job retries and the
  # failure is reported, instead of being swallowed by the production default
  # (raise_delivery_errors = false).
  def deliver_via_smtp(message, smtp_settings)
    message.delivery_method(:smtp, smtp_settings)
    message.raise_delivery_errors = true
  end

  # The test environment keeps Mail::TestMailer so specs can inspect
  # deliveries; everywhere else an undeliverable message is dropped outright
  # (Mail::TestMailer would retain every message in memory for the life of
  # the process). Mail resolves only its own symbols here, so the class goes
  # in directly.
  def null_delivery_method
    Rails.env.test? ? :test : NullMailDelivery
  end

  def rewrite_from(message, smtp_from)
    from = smtp_from.to_s.split(',').sample

    if from.match?(User::FULL_EMAIL_REGEXP)
      message[:from] = message[:from].to_s.sub(User::EMAIL_REGEXP, from)
    else
      message.from = from
    end
  end

  # In production a message with nowhere to go is an incident (a tenant's
  # mail is silently not leaving), so it reports at error level.
  def report_missing_smtp(message, account)
    return if message.instance_variable_defined?(:@ec_missing_smtp_warned)

    text = "no SMTP config for account #{account&.id || 'none'}"

    if Rails.env.production?
      ErrorReport.error(text)
    else
      ErrorReport.warning(text)
    end

    message.instance_variable_set(:@ec_missing_smtp_warned, true)
  end
end
