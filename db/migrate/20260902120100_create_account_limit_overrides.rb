# frozen_string_literal: true

class CreateAccountLimitOverrides < ActiveRecord::Migration[8.1]
  def change
    create_table :account_limit_overrides do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.integer :completions_per_month
      t.integer :sends_per_month
      t.integer :in_flight
      t.integer :seats
      t.bigint :storage_bytes
      t.string :note

      t.timestamps
    end
  end
end
