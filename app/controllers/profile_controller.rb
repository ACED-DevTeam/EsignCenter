# frozen_string_literal: true

class ProfileController < ApplicationController
  before_action do
    authorize!(:manage, current_user)
  end

  def index; end

  # A new email address never takes effect here: it waits in
  # `unconfirmed_email` until somebody opens the link mailed TO it
  # (config.reconfirmable). Changing it also needs the current password, so
  # a borrowed or hijacked session cannot move the sign-in to a mailbox the
  # session holder owns. An impersonating operator does not have it either.
  def update_contact
    attrs = contact_params

    return refuse_email_change(attrs) if email_change?(attrs) && !current_password_valid?

    # The confirmation is mailed by SendConfirmationInstructionsJob below,
    # once; Devise's own after-commit send would mail a second link and void
    # the first.
    current_user.skip_confirmation_notification!

    if current_user.update(attrs)
      if current_user.try(:pending_reconfirmation?) && current_user.previous_changes.key?(:unconfirmed_email)
        SendConfirmationInstructionsJob.perform_async('user_id' => current_user.id)

        redirect_to settings_profile_index_path,
                    notice: I18n.t('a_confirmation_email_has_been_sent_to_the_new_email_address')
      else
        redirect_to settings_profile_index_path, notice: I18n.t('contact_information_has_been_update')
      end
    else
      render :index, status: :unprocessable_content
    end
  end

  def update_password
    if current_user.update_with_password(password_params)
      bypass_sign_in(current_user)
      redirect_to settings_profile_index_path, notice: I18n.t('password_has_been_changed')
    else
      render :index, status: :unprocessable_content
    end
  end

  private

  def email_change?(attrs)
    attrs.key?(:email) && attrs[:email].to_s.strip.downcase != current_user.email.to_s.downcase
  end

  def current_password_valid?
    password = params[:current_password].to_s

    password.present? && current_user.valid_password?(password)
  end

  def refuse_email_change(attrs)
    current_user.assign_attributes(attrs)
    @email_change_password_error = I18n.t('wrong_password')

    render :index, status: :unprocessable_content
  end

  def contact_params
    params.require(:user).permit(:first_name, :last_name, :email)
  end

  def password_params
    params.require(:user).permit(:password, :password_confirmation, :current_password)
  end
end
