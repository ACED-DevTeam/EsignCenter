# frozen_string_literal: true

class SmtpFailureMailer < ApplicationMailer
  def delivery_failed(account, failure, kind:, recipients:)
    @current_account = account
    mail_account(account)
    admins = admin_recipients(account)
    return if admins.blank?

    @kind = kind
    @recipients = recipients
    @failed_at = Time.iso8601(failure.fetch('failed_at')).utc.strftime('%-d %B %Y at %H:%M UTC')
    @reason = failure.fetch('reason')
    @settings_url = settings_email_index_url

    mail(to: admins, subject: 'Your EsignCenter email server could not send a message')
  end

  private

  def platform_notice?
    true
  end
end
