# frozen_string_literal: true

# A member who no longer holds a seat (Session 7 Phase B, D43).
#
# When a paid account drops back to the free plan it has one seat and probably
# several people. Nobody is deleted and nothing is purged: the admin keeps
# full access, everyone else is marked read-only — they can still sign in,
# read, download and export, and they simply cannot create or change anything.
# The admin then chooses who keeps the seat.
#
# Read-only members never count towards seat occupancy, which is what makes
# "one seat, four people" a state the account can actually sit in.
class AddReadOnlyAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :read_only_at, :datetime

    # Seat occupancy is counted on every invite and every quota check, and
    # read-only members are the slice being excluded.
    add_index :users, :read_only_at, where: 'read_only_at IS NOT NULL'
  end
end
