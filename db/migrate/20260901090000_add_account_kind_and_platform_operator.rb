# frozen_string_literal: true

class AddAccountKindAndPlatformOperator < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :account_kind, :string, null: false, default: 'customer'
    add_index :accounts, :account_kind

    add_column :users, :platform_operator, :boolean, null: false, default: false
  end
end
