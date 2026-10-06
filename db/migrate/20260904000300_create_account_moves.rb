# frozen_string_literal: true

# One line per "join this team" (D50): a person who had their own account
# accepted an invitation, and everything they owned — templates, folders,
# documents — moved with them into the team. The old account is archived
# rather than deleted, because its metering and its /verify history are still
# true; this table is how the operator console answers "where did account 412
# go?" months later.
class CreateAccountMoves < ActiveRecord::Migration[8.1]
  def change
    create_table :account_moves do |t|
      t.references :from_account, null: false, foreign_key: { to_table: :accounts }
      t.references :to_account, null: false, foreign_key: { to_table: :accounts }
      t.references :user, null: false, foreign_key: true

      # An audit line is written once and never touched again, so there is
      # nothing for an updated_at to say.
      t.datetime :created_at, null: false
    end
  end
end
