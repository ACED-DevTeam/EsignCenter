# frozen_string_literal: true

# Every webhook Stripe sends us lands here first, verified and raw, exactly
# once (the unique event id is the deduplication): the endpoint stores and
# acknowledges, a Sidekiq job processes. Nothing is ever processed inline, so
# a slow or broken processor can never make Stripe give up on a delivery.
class CreateStripeEventInboxes < ActiveRecord::Migration[8.1]
  def change
    create_table :stripe_event_inboxes do |t|
      t.string :stripe_event_id, null: false
      t.string :event_type, null: false
      t.string :api_version
      t.text :payload, null: false
      t.string :status, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.datetime :processed_at
      # No foreign key: an event may arrive for a customer no account owns
      # (another environment's Stripe account, a deleted account), and it must
      # still be stored so the operator can see it.
      t.bigint :account_id
      t.datetime :stripe_created_at

      t.timestamps
    end

    add_index :stripe_event_inboxes, :stripe_event_id, unique: true
    add_index :stripe_event_inboxes, :status
    add_index :stripe_event_inboxes, :account_id
    add_index :stripe_event_inboxes, %i[event_type stripe_created_at]
  end
end
