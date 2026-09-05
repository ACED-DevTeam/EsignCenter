# frozen_string_literal: true

class TemplateMailer < ApplicationMailer
  def otp_verification_email(template, email:)
    @current_account = template.account
    mail_account(@current_account)
    @template = template

    @otp_code = EmailVerificationCodes.generate([email.downcase.strip, template.slug].join(':'))

    assign_message_metadata('otp_verification_email', template)

    mail(to: email, subject: I18n.t('email_verification'))
  end

  # Deliberately NOT a platform notice, and the mirror image of UserMailer's
  # decision. This code goes to a SIGNER opening the account's shared link — the
  # customer's own correspondence with their counterparty — so an account that
  # has paid for branding removal gets no wordmark and no support address on
  # it, exactly as with every other signer mail (SubmitterMailer). The
  # inherited `false` is what we want; it is written down because "verification
  # code from the platform" reads like a platform notice and is not one.
end
