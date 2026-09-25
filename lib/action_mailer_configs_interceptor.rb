# frozen_string_literal: true

module ActionMailerConfigsInterceptor
  module_function

  def delivering_email(message)
    # Idempotent: the development server re-registers this interceptor on every
    # code reload (a new module object each time), so one message can pass
    # through here twice. The first pass strips the account header, so a
    # second pass would resolve no account and re-route the mail — skip it.
    return message if message.instance_variable_get(:@ec_mail_config_applied)

    message.instance_variable_set(:@ec_mail_config_applied, true)

    account_id = message['X-EC-Account-Id']&.value
    route = message['X-EC-Mail-Route']&.value
    message['X-EC-Account-Id'] = nil
    message['X-EC-Mail-Route'] = nil

    account = Account.find_by(id: account_id) if account_id.present?

    if Docuseal.demo?
      message.delivery_method(null_delivery_method)

      return message
    end

    unless MailConfigs.delivery_mode == 'smtp'
      # Never let a real SMTP transport survive a non-smtp delivery mode (a
      # production dry run must not email customers), and never let
      # Mail::TestMailer hoard messages outside the test suite. Developer
      # transports (letter_opener) stay as they are.
      message.delivery_method(null_delivery_method) if replace_with_null?(message)

      return message
    end

    result = MailConfigs.resolve(account, platform: route == 'platform')

    case result.source
    when :account
      deliver_via_smtp(message, result.smtp)
      monitor_account_delivery(message, result) unless route == 'smtp-test'
      message.from = result.from
    when :env
      deliver_via_smtp(message, result.smtp)
      rewrite_from(message, result.from) if result.from
      set_message_stream(message, account)
    when :none
      message.delivery_method(null_delivery_method)
      report_missing_smtp(message, account)
    end

    message
  end

  def monitor_account_delivery(message, result)
    message.delivery_method(AccountSmtpDelivery, result.smtp)
    message.delivery_method.account_id = result.account.id
  end

  # A failed SMTP send must raise so the Sidekiq mail job retries and the
  # failure is reported, instead of being swallowed by the production default
  # (raise_delivery_errors = false).
  def deliver_via_smtp(message, smtp_settings)
    message.delivery_method(:smtp, smtp_settings)
    message.raise_delivery_errors = true
  end

  # Transports that must not survive a non-smtp delivery mode: a real SMTP
  # transport anywhere, and Mail::TestMailer outside the test environment
  # (where it IS the null method and is left as it is). Mail loads its
  # transports lazily, so they are resolved here at call time.
  def replace_with_null?(message)
    transport = message.delivery_method

    return true if transport.is_a?(Mail::SMTP)

    transport.is_a?(Mail::TestMailer) && !Rails.env.test?
  end

  # The test environment keeps Mail::TestMailer so specs can inspect
  # deliveries; everywhere else an undeliverable message is dropped outright
  # (Mail::TestMailer would retain every message in memory for the life of
  # the process). Mail resolves only its own symbols here, so the class goes
  # in directly.
  def null_delivery_method
    Rails.env.test? ? :test : NullMailDelivery
  end

  # Platform mail leaves on a Postmark message stream chosen by plan: free
  # accounts on the free stream, everything else (paid, internal, operator
  # alerts and other mail with no account) on the paid stream, so a spammy
  # free tier cannot hurt paying customers' deliverability. Only the
  # platform server (:env) gets the header — a pinned per-account server is
  # a different Postmark server with its own streams. Both env vars must be
  # set; with either missing, no header and one shared stream.
  def set_message_stream(message, account)
    paid_stream = ENV['POSTMARK_STREAM_PAID'].presence
    free_stream = ENV['POSTMARK_STREAM_FREE'].presence

    return if paid_stream.blank? || free_stream.blank?

    free = account.present? && Plans.key_for(account) == Plans::FREE

    message['X-PM-Message-Stream'] = free ? free_stream : paid_stream
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
