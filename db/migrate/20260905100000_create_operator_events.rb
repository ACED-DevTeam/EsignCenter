# frozen_string_literal: true

# The operator console's audit log (Session 8): one row for every change the
# console makes to somebody's account, written in the same transaction as the
# change itself so a state that moved without a line here is impossible.
#
# `operator_user_id` is NULLABLE on purpose. Almost every row names the human
# who pressed the button, but a comp expiring is a change nobody pressed —
# CompExpiryJob applies it on the clock — and an audit that could not record
# it would be an audit with a hole in it. A NULL operator means "the system
# did this", and the console prints it that way.
#
# `account_id` is nullable for the same shape of reason: a global action (a
# platform-wide setting, a sweep) belongs in the log without belonging to one
# account. `subject_type`/`subject_id` name the thing acted on when it is
# smaller than an account — a user, an invitation, an abuse flag.
#
# Deliberately NOT in Accounts::Purge::INVENTORY: like the money history, an
# operator's audit is not the customer's to take with it. The rows hold ids,
# actions and the operator's own typed reason, never documents or signers,
# and they point at the tombstone the purge leaves behind.
class CreateOperatorEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :operator_events do |t|
      t.references :operator_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :account, foreign_key: true
      t.string :subject_type
      t.bigint :subject_id
      t.string :action, null: false
      t.text :reason
      # jsonb, as abuse_flags.details already is: the console reads these back
      # (a limits change prints its before and after), so they have to be
      # queryable rather than an opaque string.
      t.jsonb :details, null: false, default: {}
      t.string :ip

      # An audit line is written once and never touched again, so there is
      # nothing for an updated_at to say (the same shape as account_moves).
      t.datetime :created_at, null: false
    end

    add_index :operator_events, %i[account_id created_at]
    add_index :operator_events, %i[operator_user_id created_at]
    add_index :operator_events, :action
    add_index :operator_events, %i[subject_type subject_id]
  end
end
