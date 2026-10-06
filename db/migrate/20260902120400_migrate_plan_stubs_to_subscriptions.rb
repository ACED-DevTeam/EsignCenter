# frozen_string_literal: true

# Session 3 marked paid accounts with an account_configs row (key 'plan_stub',
# JSON value "paid"). Session 5 replaced the stub with the real subscription
# row: every stubbed account gets an active, manually granted, one-seat
# subscription (unless it already has a row), and the stub rows go away.
# String literals rather than application constants so the migration never
# depends on code that has since moved on.
class MigratePlanStubsToSubscriptions < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO account_subscriptions
        (account_id, access_state, status, quantity, cancel_at_period_end, created_at, updated_at)
      SELECT stubs.account_id, 'active', 'manual', 1, false, NOW(), NOW()
      FROM account_configs stubs
      WHERE stubs.key = 'plan_stub'
        AND stubs.value = '"paid"'
        AND NOT EXISTS (
          SELECT 1 FROM account_subscriptions existing WHERE existing.account_id = stubs.account_id
        )
    SQL

    execute "DELETE FROM account_configs WHERE key = 'plan_stub'"
  end

  def down
    # Nothing to undo: the stub rows are gone by design and the subscription
    # rows they became are real plan data now (a downgrade never purges, D43).
  end
end
