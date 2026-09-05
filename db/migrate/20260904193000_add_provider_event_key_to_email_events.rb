# frozen_string_literal: true

class AddProviderEventKeyToEmailEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :email_events, :provider_event_key, :string
    add_index :email_events, :provider_event_key, unique: true, where: 'provider_event_key IS NOT NULL'
  end
end
