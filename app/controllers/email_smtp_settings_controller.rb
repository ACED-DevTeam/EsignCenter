# frozen_string_literal: true

class EmailSmtpSettingsController < ApplicationController
  before_action :load_encrypted_config
  authorize_resource :encrypted_config, only: :index
  authorize_resource :encrypted_config, parent: false, only: %i[create destroy]
  # Per-account SMTP is paid-only (internal accounts are pinned by rake and
  # always entitled). Declared as a before_action so the refusal reaches
  # ApplicationController's handler instead of the rescue below. Clearing or
  # removing the settings is always allowed: a downgraded account keeps the
  # power to drop a pin it can no longer use.
  before_action :require_smtp_entitlement!, only: :create

  def index; end

  def create
    if @encrypted_config.update(email_configs)
      SettingsMailer.smtp_successful_setup(
        @encrypted_config.value['from_email'] || current_user.email,
        current_account
      ).deliver_now!

      AccountSmtpFailures.clear(current_account)

      redirect_to settings_email_index_path, notice: I18n.t('changes_have_been_saved')
    else
      render :index, status: :unprocessable_content
    end
  rescue StandardError => e
    flash[:alert] = e.message

    render :index, status: :unprocessable_content
  end

  def destroy
    @encrypted_config.destroy! if @encrypted_config.persisted?
    AccountSmtpFailures.clear(current_account)

    redirect_to settings_email_index_path, notice: I18n.t('smtp_settings_have_been_removed')
  end

  private

  def require_smtp_entitlement!
    return if email_configs[:value].blank?

    Entitlements.require!(current_account, :account_smtp)
  end

  def load_encrypted_config
    @encrypted_config =
      EncryptedConfig.find_or_initialize_by(account: current_account, key: EncryptedConfig::EMAIL_SMTP_KEY)
  end

  def email_configs
    params.require(:encrypted_config).permit(value: {}).tap do |e|
      e[:value].compact_blank!
    end
  end
end
