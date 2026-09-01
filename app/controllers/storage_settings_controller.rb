# frozen_string_literal: true

class StorageSettingsController < ApplicationController
  before_action :require_operator_account
  before_action :load_encrypted_config
  authorize_resource :encrypted_config, only: :index
  authorize_resource :encrypted_config, parent: false, only: :create

  def index; end

  def create
    if @encrypted_config.update(storage_configs)
      LoadActiveStorageConfigs.reload

      redirect_to settings_storage_index_path, notice: I18n.t('changes_have_been_saved')
    else
      render :index, status: :unprocessable_content
    end
  end

  private

  def require_operator_account
    head :not_found unless current_account.operator?
  end

  def load_encrypted_config
    @encrypted_config =
      EncryptedConfig.find_or_initialize_by(account: current_account, key: EncryptedConfig::FILES_STORAGE_KEY)
  end

  def storage_configs
    params.require(:encrypted_config).permit(value: {}).tap do |e|
      e[:value].compact_blank!

      e.dig(:value, :configs)&.compact_blank!
    end
  end
end
