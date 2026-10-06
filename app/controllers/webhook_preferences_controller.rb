# frozen_string_literal: true

class WebhookPreferencesController < ApplicationController
  load_and_authorize_resource :webhook_url, parent: false

  # Webhooks are paid-only: changing which events a URL receives is a write
  # (reads and deleting the URL stay open — a downgrade never blocks cleanup).
  before_action -> { Entitlements.require!(current_account, :webhooks) }, only: :update

  def update
    webhook_preferences_params[:events].each do |event, val|
      @webhook_url.events.delete(event) if val == '0'
      @webhook_url.events.push(event) if val == '1' && @webhook_url.events.exclude?(event)
    end

    @webhook_url.save!

    head :ok
  end

  private

  def webhook_preferences_params
    params.require(:webhook_url).permit(events: {})
  end
end
