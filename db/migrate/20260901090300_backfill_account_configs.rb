# frozen_string_literal: true

class BackfillAccountConfigs < ActiveRecord::Migration[8.1]
  # Keys that were ACTUALLY resolved globally before de-globalization, and are
  # therefore the only keys whose values may be copied to preserve behavior.
  #
  # Why only these: the sole global fallback was inside
  # AccountConfigs.find_for_account —
  #   configs ||= Account.order(:id).first.account_configs.find_by(key:) unless Docuseal.multitenant?
  # — so exactly the keys ever passed to AccountConfigs.find_for_account /
  # AccountConfigs.find_or_initialize_for_key could ever resolve to the
  # lowest-id account. Every other config read was a direct per-account query
  # (e.g. submission.account.account_configs.find_by(key: AccountConfig::BCC_EMAILS)
  # in ProcessSubmitterCompletionJob, and AccountConfig.find_or_initialize_by(
  # account: current_account, ...) throughout the settings views), which never
  # fell back to another account. Copying those keys would not preserve
  # behavior — it would newly impose the lowest-id account's settings on
  # tenants that never had them (and, for bcc_emails, leak documents across
  # tenants).
  #
  # String literals rather than AccountConfig:: constants so the migration does
  # not depend on application code. The matching constants are named alongside.
  GLOBALLY_RESOLVED_KEYS = [
    'submitter_invitation_email',   # AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY
    'submitter_completed_email',    # AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY
    'submitter_documents_copy_email', # AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY
    'submitter_reminders',          # AccountConfig::SUBMITTER_REMINDERS
    'form_completed_button',        # AccountConfig::FORM_COMPLETED_BUTTON_KEY
    'form_completed_message',       # AccountConfig::FORM_COMPLETED_MESSAGE_KEY
    'policy_links'                  # AccountConfig::POLICY_LINKS_KEY
  ].freeze

  def up
    return if select_value('SELECT COUNT(*) FROM accounts').to_i <= 1

    allowed_keys = GLOBALLY_RESOLVED_KEYS.map { |key| quote(key) }.join(', ')

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
        AND source_configs.key IN (#{allowed_keys})
        AND target_accounts.id <> source_configs.account_id
        AND NOT EXISTS (
          SELECT 1
          FROM account_configs AS target_configs
          WHERE target_configs.account_id = target_accounts.id
            AND target_configs.key = source_configs.key
        )
        AND NOT EXISTS (
          SELECT 1
          FROM account_linked_accounts AS links
          WHERE links.linked_account_id = target_accounts.id
            AND links.account_type = 'testing'
        )
    SQL
  end

  def down
    # The copied rows are indistinguishable from operator-set values by now —
    # deleting them could destroy real settings. Roll forward only.
    raise ActiveRecord::IrreversibleMigration
  end
end
