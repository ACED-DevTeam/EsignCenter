# frozen_string_literal: true

class SettingsMailer < ApplicationMailer
  def smtp_successful_setup(email, account)
    @current_account = account
    mail_account(account)

    mail(to: email, from: email, subject: 'SMTP has been configured')
  end

  private

  # A connectivity test must exercise the saved pin and report errors to the
  # settings controller, without generating a second failure notice.
  def smtp_setup_test?
    action_name == 'smtp_successful_setup'
  end

  # Written by the platform, not by a customer: the mail layout signs it
  # with the product's name and the support address whatever the account's
  # branding-removal setting says (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
