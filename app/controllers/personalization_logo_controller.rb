# frozen_string_literal: true

class PersonalizationLogoController < ApplicationController
  MAX_LOGO_SIZE = 2.megabytes
  ALLOWED_CONTENT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze

  before_action :authorize_personalization!

  def create
    file = params[:logo]

    return redirect_with_alert('Please choose a logo image to upload.') if file.blank?

    content_type = Marcel::MimeType.for(file.tempfile)

    if ALLOWED_CONTENT_TYPES.exclude?(content_type)
      return redirect_with_alert('Logo must be a PNG, JPG, WEBP or GIF image.')
    end

    return redirect_with_alert('Logo must be smaller than 2MB.') if file.size > MAX_LOGO_SIZE

    # The logo is an account-user upload: it counts against storage like a
    # document does, and is refused the same way when the account is full.
    # A replacement frees the old logo, so only the growth counts: a full
    # account can still swap its logo for one of the same size.
    Quotas::Storage.assert_available!(current_account, [file.size - current_account.logo.blob&.byte_size.to_i, 0].max)

    file.tempfile.rewind

    current_account.logo.attach(io: file.tempfile, filename: file.original_filename, content_type:)

    Quotas::Storage.after_upload(current_account)

    redirect_back(fallback_location: settings_personalization_path, notice: I18n.t('settings_have_been_saved'))
  rescue Quotas::StorageLimitReached => e
    redirect_with_alert(e.localized_message)
  end

  def destroy
    current_account.logo.purge_later if current_account.logo.attached?

    redirect_back(fallback_location: settings_personalization_path, notice: I18n.t('settings_have_been_saved'))
  end

  private

  # Branding is an account-level admin setting.
  def authorize_personalization!
    authorize!(:manage, current_account)
  end

  def redirect_with_alert(message)
    redirect_back(fallback_location: settings_personalization_path, alert: message)
  end
end
