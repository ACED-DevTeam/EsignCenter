# frozen_string_literal: true

class CreateAccountCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :account_counters do |t|
      t.references :account, null: false, foreign_key: true
      t.string :key, null: false
      t.string :period, null: false, default: ''
      t.bigint :value, null: false, default: 0

      t.timestamps
    end

    add_index :account_counters, %i[account_id key period], unique: true
  end
end
