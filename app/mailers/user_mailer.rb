# frozen_string_literal: true

class UserMailer < ApplicationMailer
  def invitation_email(user, invited_by: nil)
    @current_account = invited_by&.account || user.account
    mail_account(@current_account)
    @user = user
    @token = @user.send(:set_reset_password_token)

    assign_message_metadata('user_invitation', @user)

    I18n.with_locale(@current_account.locale) do
      mail(to: @user.friendly_name,
           subject: I18n.t('you_are_invited_to_product_name', product_name: Docuseal.product_name))
    end
  end

  private

  # An invitation to a LOGIN on this platform, like AccountInviteMailer's: the
  # person receiving it is being asked to create an EsignCenter account, so the
  # mail has to say whose platform it is and where to write about it even when
  # the inviting account has paid for branding removal. Branding removal is
  # about the mail an account sends its SIGNERS, and the layout keeps the
  # wordmark and the support address on this one either way
  # (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
