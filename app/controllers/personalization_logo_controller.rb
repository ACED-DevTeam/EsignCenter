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

    file.tempfile.rewind

    current_account.logo.attach(io: file.tempfile, filename: file.original_filename, content_type:)

    redirect_back(fallback_location: settings_personalization_path, notice: I18n.t('settings_have_been_saved'))
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
