# frozen_string_literal: true

# A seat held for somebody who has not arrived yet (Session 7 Phase B).
#
# On a paid account a person IS a seat, and the seat is bought before the
# invitation goes out — so between "the admin paid for it" and "the colleague
# signed in" there has to be a row that occupies the seat. That row is this
# one: it counts towards occupancy exactly like a user does, it lasts
# INVITE_TOKEN_DAYS days, and when it lapses the seat is released and the next
# invoice drops back.
#
# The token is never stored: only its SHA-256 digest is, so a stolen database
# dump cannot be used to accept invitations. `collision_user_id` is set when
# the invited address already belongs to somebody else's account — that is not
# an error, it is the "join this team and bring your documents" offer (D50).
class CreateAccountInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :account_invites do |t|
      t.references :account, null: false, foreign_key: true
      # Stored downcased: an invitation to Ann@Example.com and one to
      # ann@example.com are the same invitation.
      t.string :email, null: false
      t.string :role, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.datetime :revoked_at
      # When the seat this invite held was handed back to Stripe. Expiry is by
      # timestamp, so this is not "is it expired" — it is "has the sweep
      # already dealt with it", which stops the hourly job re-doing the same
      # subscription update every hour forever.
      t.datetime :released_at
      # Both are people, and a person can be removed: an invitation outlives
      # the admin who sent it and the account it would have moved.
      t.references :invited_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :collision_user, foreign_key: { to_table: :users, on_delete: :nullify }

      t.timestamps
    end

    add_index :account_invites, :token_digest, unique: true
    add_index :account_invites, :email
    add_index :account_invites, :expires_at
  end
end
