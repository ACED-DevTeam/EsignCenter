# frozen_string_literal: true

# The one way the app tells the operator something needs a human: a sending
# pause, a reported document. One email per event to the operator's alert
# address — an AccountConfig row on the operator account when the Session 8
# console has set one, the support mailbox otherwise. Never takes the caller
# down: a failure to enqueue is reported and swallowed.
module OperatorAlert
  EMAIL_KEY = 'operator_alert_email'

  module_function

  def address
    OperatorConfigs.fetch(EMAIL_KEY).presence || Docuseal::SUPPORT_EMAIL
  end

  def deliver(subject:, body:)
    OperatorMailer.alert(subject, body).deliver_later!

    true
  rescue StandardError => e
    ErrorReport.error(e, subject:)

    false
  end
end
