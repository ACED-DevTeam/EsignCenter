# frozen_string_literal: true

# Account suspension: the state between "paying" and "gone". A suspended
# account can still be signed into, read, downloaded and exported, and the
# documents already in flight can still be finished — it simply cannot create
# or change anything until whatever suspended it is settled.
#
# `suspension_reason` says who owns lifting it, and only the owner may
# (AccountStates::SUSPENSION_REASONS): 'billing' is written by the dunning
# clock and lifted the moment the card goes through, 'operator' by a human,
# 'deletion' by a scheduled account deletion. A billing recovery must never
# quietly undo an operator's decision, which is why the reason is a column
# rather than a boolean.
class AddSuspensionToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :suspended_at, :datetime
    add_column :accounts, :suspension_reason, :string

    # The nightly/hourly sweeps and the operator console both ask "who is
    # suspended right now", and that is a tiny slice of the table.
    add_index :accounts, :suspended_at, where: 'suspended_at IS NOT NULL'
  end
end
