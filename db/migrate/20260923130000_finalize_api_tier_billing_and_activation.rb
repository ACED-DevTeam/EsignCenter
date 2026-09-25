# frozen_string_literal: true

class FinalizeApiTierBillingAndActivation < ActiveRecord::Migration[8.1]
  def change
    add_column :account_subscriptions, :retained_business_until, :datetime
    add_column :completed_submitters, :submission_created_at, :datetime

    create_table :api_metering_activations do |t|
      t.string :key, null: false
      t.datetime :starts_at, null: false
      t.timestamps
    end
    add_index :api_metering_activations, :key, unique: true

    create_table :api_pack_purchases do |t|
      t.references :account_subscription, null: false, foreign_key: true
      t.string :operation_key, null: false
      t.string :stripe_subscription_id, null: false
      t.string :stripe_customer_id, null: false
      t.string :stripe_invoice_id
      t.integer :previous_quantity, null: false
      t.integer :quantity, null: false
      t.integer :added_quantity, null: false
      t.datetime :paid_at
      t.datetime :applied_at
      t.datetime :closed_at
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :api_pack_purchases, :operation_key, unique: true
    add_index :api_pack_purchases, :stripe_invoice_id, unique: true
    add_index :api_pack_purchases, :account_subscription_id, unique: true,
                                                             where: 'applied_at IS NULL AND closed_at IS NULL',
                                                             name: 'index_one_open_api_pack_purchase'

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE completed_submitters SET submission_created_at =
            (SELECT submissions.created_at FROM submissions WHERE submissions.id = completed_submitters.submission_id)
        SQL
        execute <<~SQL.squish
          INSERT INTO api_metering_activations (key, starts_at, created_at, updated_at)
          VALUES ('api_usage_tiers', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end
  end
end
