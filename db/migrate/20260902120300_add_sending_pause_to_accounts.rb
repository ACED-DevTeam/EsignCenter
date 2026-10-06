# frozen_string_literal: true

class AddSendingPauseToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :sending_paused_at, :datetime
    add_column :accounts, :sending_pause_reason, :string
  end
end
