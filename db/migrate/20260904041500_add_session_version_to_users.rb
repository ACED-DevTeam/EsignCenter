# frozen_string_literal: true

# The server-side handle on "every browser this person is signed in on"
# (review 7, D50 D1).
#
# Devise serialises a session as the user id plus `authenticatable_salt`, and
# re-validates that salt out of the database on EVERY request. Out of the box
# the salt is a slice of the password hash, so the only way to end somebody
# else's live session was to change their password — which is not ours to
# change when what actually happened is that they crossed a TENANT boundary
# by joining a team (Accounts::MoveUser).
#
# This column is appended to the salt (User#authenticatable_salt), so bumping
# it invalidates every outstanding session cookie and every remember-me cookie
# for that person the instant the transaction that bumped it commits. It is a
# counter rather than a token because nothing ever has to guess it: it is
# compared against the number the cookie was minted with, and one more is
# always different from what came before.
#
# Deploying this changes every existing user's salt exactly once (0 is
# appended where nothing was before), so everybody signs in again on the day
# it ships. That is a one-off, and it is the cheap half of the trade.
class AddSessionVersionToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :session_version, :integer, default: 0, null: false
  end
end
