# frozen_string_literal: true

class ApiSettingsController < ApplicationController
  def index
    authorize!(:read, current_user.access_token)
  end

  # Rotating the token replaces it: every integration using the old one
  # stops working. That is a write, and it is authorized as one so a frozen
  # account cannot do it (the page itself stays readable).
  def create
    authorize!(:update, current_user.access_token)

    current_user.access_token.token = SecureRandom.base58(AccessToken::TOKEN_LENGTH)

    current_user.access_token.save!

    redirect_back(fallback_location: settings_api_index_path, notice: I18n.t('api_token_has_been_updated'))
  end
end
