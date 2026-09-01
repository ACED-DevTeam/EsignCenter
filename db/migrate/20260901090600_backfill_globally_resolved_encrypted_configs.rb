# frozen_string_literal: true

class BackfillGloballyResolvedEncryptedConfigs < ActiveRecord::Migration[8.1]
  # Two encrypted_configs keys were resolved globally before de-globalization
  # and, unlike esign_certs (20260901090400), got no data-preservation copy:
  #
  #   action_mailer_smtp   lib/action_mailer_configs_interceptor.rb (pre-change)
  #                        EncryptedConfig.order(:account_id).find_by(key: EMAIL_SMTP_KEY)
  #                        — EVERY account's mail left through the pinned SMTP
  #                        server of the lowest account HOLDING the key (not
  #                        necessarily account #1). The new MailConfigs.resolve
  #                        reads only the account's own row, then the SMTP_*
  #                        env, then drops the mail (:none), so without this
  #                        copy every other pre-existing account silently stops
  #                        sending on a host with no SMTP_* env.
  #   timestamp_server_url lib/accounts.rb#load_timeserver_url (pre-change)
  #                        Account.order(:id).first.encrypted_configs.find_by(key: TIMESTAMP_SERVER_URL_KEY)
  #                        — an account without its own row was timestamped by
  #                        the LOWEST ACCOUNT's own row; if that account had no
  #                        row the fallback was nil (env), even when some later
  #                        account had set one. The new lookup reads the
  #                        account's own row then TIMESERVER_URL env, so other
  #                        accounts' signed PDFs would silently lose their
  #                        timestamp.
  #
  # Preserve the exact effective behavior the way 20260901090400 does: copy the
  # row the old global fallback actually resolved to, to every non-testing
  # account that lacks a row for that key. The source-row rule differs per key
  # because the two old fallbacks differed:
  #
  #   action_mailer_smtp   the row of the lowest account_id that holds the key
  #                        (MIN(account_id) WHERE key = ...).
  #   timestamp_server_url the lowest account's own row (account_id =
  #                        MIN(accounts.id)); nothing is copied when that
  #                        account has no row, because nobody inherited one.
  #
  # Accounts that already hold their own row keep it. (Testing accounts resolve
  # their parent's pins at runtime.) Active Record encryption ciphertext is
  # self-contained, so a raw copy of the encrypted value stays decryptable.
  #
  # String literals rather than EncryptedConfig:: constants so the migration
  # does not depend on application code. The matching constants are named
  # alongside.
  SOURCE_ACCOUNT_BY_KEY = {
    # EncryptedConfig::EMAIL_SMTP_KEY — lowest account holding the key
    'action_mailer_smtp' => "(SELECT MIN(account_id) FROM encrypted_configs WHERE key = 'action_mailer_smtp')",
    # EncryptedConfig::TIMESTAMP_SERVER_URL_KEY — lowest account, own row only
    'timestamp_server_url' => '(SELECT MIN(id) FROM accounts)'
  }.freeze

  GLOBALLY_RESOLVED_KEYS = SOURCE_ACCOUNT_BY_KEY.keys.freeze

  def up
    return if select_value('SELECT COUNT(*) FROM accounts').to_i <= 1

    SOURCE_ACCOUNT_BY_KEY.each do |key, source_account_sql|
      quoted_key = quote(key)

      execute <<~SQL.squish
        INSERT INTO encrypted_configs (account_id, key, value, created_at, updated_at)
        SELECT target_accounts.id, source_config.key, source_config.value, NOW(), NOW()
        FROM accounts AS target_accounts
          CROSS JOIN (
            SELECT key, value
            FROM encrypted_configs
            WHERE key = #{quoted_key}
              AND account_id = #{source_account_sql}
          ) AS source_config
        WHERE NOT EXISTS (
                SELECT 1 FROM encrypted_configs AS existing
                WHERE existing.account_id = target_accounts.id AND existing.key = #{quoted_key}
              )
          AND NOT EXISTS (
                SELECT 1 FROM account_linked_accounts AS links
                WHERE links.linked_account_id = target_accounts.id AND links.account_type = 'testing'
              )
      SQL
    end
  end

  def down
    # The copied rows are indistinguishable from per-account pins by now —
    # deleting them could destroy a pin an operator set (rake email:pin writes
    # the same row). Roll forward only.
    raise ActiveRecord::IrreversibleMigration
  end
end
