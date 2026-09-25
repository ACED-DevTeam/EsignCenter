# frozen_string_literal: true

module AccountSmtpFailures
  WINDOW = 24.hours
  MESSAGE_KINDS = {
    'submitter_invitation' => 'Signature request',
    'submitter_completed' => 'Completed notification',
    'submitter_declined' => 'Declined notification',
    'submitter_documents_copy' => 'Document copy',
    'otp_verification_email' => 'Email verification code'
  }.freeze

  module_function

  def record(account_id, message, error, smtp_settings)
    account = Account.find_by(id: account_id)
    return unless account

    failure = claim(account, error, smtp_settings)
    return unless failure

    tag = message.instance_variable_get(:@message_metadata)&.dig('tag')
    kind = MESSAGE_KINDS.fetch(tag) { tag.presence&.humanize || 'Account email' }
    SmtpFailureMailer.delivery_failed(account, failure, kind:, recipients: message.destinations).deliver_now!
  rescue StandardError => e
    # Never mask the original delivery error, and never log a server's raw
    # reply here: it can echo credentials. ErrorReport itself is non-raising.
    ErrorReport.error('Could not send SMTP failure notice', account_id:, reason: reason_for(e))
  end

  # Like quota warnings, claim in the database before sending. Lock the
  # account (which always exists), not a marker that two workers could both
  # create. No SMTP connection is held inside the transaction. A failed notice
  # attempt consumes the window too, so retries cannot flood administrators.
  def claim(account, error, smtp_settings)
    account.with_lock do
      current = MailConfigs.resolve(account)
      next unless current.source == :account
      next unless Mail::SMTP::DEFAULTS.merge(current.smtp) == smtp_settings

      config = AccountConfig.find_or_initialize_by(account:, key: AccountConfig::SMTP_FAILURE_KEY)
      value = config.value || {}
      now = Time.current
      notify = value['notified_at'].blank? || Time.iso8601(value['notified_at']) <= now - WINDOW
      value = value.merge('failed_at' => now.iso8601(6), 'reason' => reason_for(error))
      value['notified_at'] = now.iso8601(6) if notify
      config.update!(value:)

      value if notify
    end
  end

  # Only allowlisted descriptions reach storage, logs and mail. Redacting a
  # raw exception string cannot safely cover encoded passwords or SMTP AUTH.
  def reason_for(error)
    case error
    when Net::SMTPAuthenticationError
      'The email server did not accept the sign-in details.'
    when Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      'The email server took too long to respond.'
    when OpenSSL::SSL::SSLError
      'A secure connection to the email server could not be established.'
    when SocketError, SystemCallError, IOError
      'The email server could not be reached or closed the connection.'
    when Net::SMTPError
      'The email server refused the message.'
    else
      'The message could not be sent through the email server.'
    end
  end

  def recent(account)
    value = AccountConfig.find_by(account:, key: AccountConfig::SMTP_FAILURE_KEY)&.value

    value if value&.dig('failed_at') && Time.iso8601(value['failed_at']) > WINDOW.ago
  end

  def clear(account)
    account.with_lock do
      config = AccountConfig.find_by(account:, key: AccountConfig::SMTP_FAILURE_KEY)
      # Keep the throttle after fixing/removing settings: a remove-and-retry
      # sequence must not send two notices in the same 24 hours.
      config&.update!(value: config.value.slice('notified_at'))
    end
  end
end
