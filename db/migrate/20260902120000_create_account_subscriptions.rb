# frozen_string_literal: true

class CreateAccountSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :account_subscriptions do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.string :access_state, null: false
      t.string :status
      t.integer :quantity, null: false, default: 1
      t.string :stripe_customer_id
      t.string :stripe_subscription_id
      t.string :stripe_item_id
      t.string :stripe_product_id
      t.string :stripe_price_id
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.datetime :trial_end
      t.boolean :cancel_at_period_end, null: false, default: false

      t.timestamps
    end

    add_index :account_subscriptions, :stripe_customer_id, unique: true, where: 'stripe_customer_id IS NOT NULL'
    add_index :account_subscriptions, :stripe_subscription_id, unique: true,
                                                               where: 'stripe_subscription_id IS NOT NULL'
  end
end
