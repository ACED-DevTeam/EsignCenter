# frozen_string_literal: true

class CreateProvisioningEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :provisioning_events do |t|
      t.references :account, null: false, foreign_key: true
      t.string :idempotency_key
      t.string :email, null: false
      t.bigint :webhook_url_id

      t.timestamps
    end

    add_index(
      :provisioning_events,
      :idempotency_key,
      unique: true,
      where: 'idempotency_key IS NOT NULL'
    )
  end
end
