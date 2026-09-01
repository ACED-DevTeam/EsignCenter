# frozen_string_literal: true

class BackfillAccountConfigs < ActiveRecord::Migration[8.1]
  def up
    return if select_value('SELECT COUNT(*) FROM accounts').to_i <= 1

    execute <<~SQL.squish
      INSERT INTO account_configs (account_id, key, value, created_at, updated_at)
      SELECT target_accounts.id,
             source_configs.key,
             source_configs.value,
             CURRENT_TIMESTAMP,
             CURRENT_TIMESTAMP
      FROM accounts AS target_accounts
      CROSS JOIN account_configs AS source_configs
      WHERE source_configs.account_id = (SELECT MIN(id) FROM accounts)
        AND target_accounts.id <> source_configs.account_id
        AND NOT EXISTS (
          SELECT 1
          FROM account_configs AS target_configs
          WHERE target_configs.account_id = target_accounts.id
            AND target_configs.key = source_configs.key
        )
    SQL
  end
end
