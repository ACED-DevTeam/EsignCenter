# frozen_string_literal: true

# Existing subscriptions stay Paid with their 50-completion API allowance;
# adopting Business and packs never depends on rewriting historical rows.
class AddApiUsageTiers < ActiveRecord::Migration[8.1]
  def change
    change_table :account_subscriptions, bulk: true do |t|
      t.string :plan, null: false, default: 'paid'
      t.integer :api_pack_quantity, null: false, default: 0
      t.integer :retained_api_pack_quantity, null: false, default: 0
      t.datetime :retained_api_pack_until
    end
    add_column :account_limit_overrides, :api_completions_per_month, :integer
  end
end
