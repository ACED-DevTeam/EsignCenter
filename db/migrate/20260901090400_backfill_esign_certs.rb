# frozen_string_literal: true

class BackfillEsignCerts < ActiveRecord::Migration[8.1]
  # Before de-globalization, an account without its own esign_certs row
  # silently signed with the lowest-id account's certificates (the global
  # fallback). That fallback is gone and signing now raises for cert-less
  # accounts, so preserve the exact effective behavior: copy the lowest-id
  # account's cert row to every non-testing account that lacks one.
  # (Testing accounts resolve their parent's certs at runtime.)
  # Active Record encryption ciphertext is self-contained, so a raw copy of
  # the encrypted value stays decryptable.
  def up
    execute <<~SQL.squish
      INSERT INTO encrypted_configs (account_id, key, value, created_at, updated_at)
      SELECT target_accounts.id, source_config.key, source_config.value, NOW(), NOW()
      FROM accounts AS target_accounts
        CROSS JOIN (
          SELECT key, value
          FROM encrypted_configs
          WHERE key = 'esign_certs'
            AND account_id = (SELECT MIN(account_id) FROM encrypted_configs WHERE key = 'esign_certs')
        ) AS source_config
      WHERE NOT EXISTS (
              SELECT 1 FROM encrypted_configs AS existing
              WHERE existing.account_id = target_accounts.id AND existing.key = 'esign_certs'
            )
        AND NOT EXISTS (
              SELECT 1 FROM account_linked_accounts AS links
              WHERE links.linked_account_id = target_accounts.id AND links.account_type = 'testing'
            )
    SQL
  end

  def down
    # The copied rows are indistinguishable from per-account certs by now.
    raise ActiveRecord::IrreversibleMigration
  end
end
