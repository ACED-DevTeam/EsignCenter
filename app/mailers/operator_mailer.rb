# frozen_string_literal: true

# Plain-text notices to the platform operator (OperatorAlert). No account
# header on purpose: the mail is the platform's own, so it leaves through the
# platform server on the paid stream, never through a customer's pinned SMTP.
class OperatorMailer < ApplicationMailer
  def alert(subject, body)
    @body = body

    mail(to: OperatorAlert.address, subject: "[EsignCenter] #{subject}")
  end

  private

  # Written by the platform, not by a customer: the mail layout signs it
  # with the product's name and the support address whatever the account's
  # branding-removal setting says (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
