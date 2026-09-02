# frozen_string_literal: true

# Plain-text notices to the platform operator (OperatorAlert). No account
# header on purpose: the mail is the platform's own, so it leaves through the
# platform server on the paid stream, never through a customer's pinned SMTP.
class OperatorMailer < ApplicationMailer
  def alert(subject, body)
    @body = body

    mail(to: OperatorAlert.address, subject: "[EsignCenter] #{subject}")
  end
end
