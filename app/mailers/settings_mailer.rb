# frozen_string_literal: true

class SettingsMailer < ApplicationMailer
  def smtp_successful_setup(email, account)
    @current_account = account
    mail_account(account)

    mail(to: email, from: email, subject: 'SMTP has been configured')
  end

  private

  # Written by the platform, not by a customer: the mail layout signs it
  # with the product's name and the support address whatever the account's
  # branding-removal setting says (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
