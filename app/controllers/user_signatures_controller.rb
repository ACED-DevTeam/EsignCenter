# frozen_string_literal: true

class UserSignaturesController < ApplicationController
  before_action :load_user_config
  authorize_resource :user_config

  def edit; end

  def update
    file = params[:file]

    return redirect_to settings_profile_index_path, notice: I18n.t('unable_to_save_signature') if file.blank?

    extension = File.extname(file.original_filename).delete_prefix('.').downcase

    if Submitters::DANGEROUS_EXTENSIONS.include?(extension)
      raise Submitters::MaliciousFileExtension, "File type '.#{extension}' is not allowed."
    end

    # An account-user upload like any other: it counts against storage and
    # is refused the same way when the account is full (lib/quotas/storage.rb).
    Quotas::Storage.assert_available!(current_account, Quotas::Storage.file_size(file))

    blob = ActiveStorage::Blob.create_and_upload!(io: file.open,
                                                  filename: file.original_filename,
                                                  content_type: file.content_type)

    attachment = ActiveStorage::Attachment.create!(
      blob:,
      name: 'signature',
      record: current_user
    )

    Quotas::Storage.after_upload(current_account)

    if @user_config.update(value: attachment.uuid)
      redirect_to settings_profile_index_path, notice: I18n.t('signature_has_been_saved')
    else
      redirect_to settings_profile_index_path, notice: I18n.t('unable_to_save_signature')
    end
  rescue Quotas::StorageLimitReached => e
    redirect_to settings_profile_index_path, alert: e.localized_message
  end

  def destroy
    @user_config.destroy

    redirect_to settings_profile_index_path, notice: I18n.t('signature_has_been_removed')
  end

  private

  def load_user_config
    @user_config =
      UserConfig.find_or_initialize_by(user: current_user, key: UserConfig::SIGNATURE_KEY)
  end
end
