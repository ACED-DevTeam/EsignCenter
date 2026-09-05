# frozen_string_literal: true

# One row per "give me everything in this account as a zip" (Session 8 phase
# D). The row is the whole state machine — pending, running, ready, failed,
# expired — so the page can tell the truth while the job is still working and
# afterwards, and so the daily limit and the "one at a time" rule have
# something durable to read.
#
# `requested_by_id` nullifies rather than restricting: the person who asked
# can be deleted (a seat removed, a purge) long before the file expires, and
# an export that outlives them is still the account's export.
#
# The zip itself is an ActiveStorage attachment (`archive`), so it is deleted
# by the same walk that deletes every other file of the account — and
# `account_exports` is in Accounts::Purge::INVENTORY for the rows.
class CreateAccountExports < ActiveRecord::Migration[8.1]
  def change
    create_table :account_exports do |t|
      t.references :account, null: false, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :status, null: false, default: 'pending'
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :expires_at
      t.text :error
      # jsonb like operator_events.details: the page reads counts and the size
      # back out of it, so it has to be queryable rather than an opaque blob.
      t.jsonb :summary, null: false, default: {}

      t.timestamps
    end

    add_index :account_exports, %i[account_id created_at]
  end
end
