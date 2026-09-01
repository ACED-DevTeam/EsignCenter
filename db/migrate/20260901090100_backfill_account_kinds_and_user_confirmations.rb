# frozen_string_literal: true

class BackfillAccountKindsAndUserConfirmations < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE accounts
      SET account_kind = 'internal'
    SQL

    execute <<~SQL.squish
      UPDATE users
      SET confirmed_at = created_at
      WHERE confirmed_at IS NULL
    SQL
  end

  def down; end
end
