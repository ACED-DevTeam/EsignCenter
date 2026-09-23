# frozen_string_literal: true

require 'mail/network/delivery_methods/smtp'

# The transport is the one choke point shared by deliver_now!, deliver_now
# and Sidekiq's MailDeliveryJob. Only account-routed mail uses this wrapper;
# platform mail and the interactive setup test use Mail::SMTP directly.
class AccountSmtpDelivery < Mail::SMTP
  attr_accessor :account_id

  def deliver!(message)
    super
  rescue StandardError => e
    AccountSmtpFailures.record(account_id, message, e, settings)

    raise
  end
end
