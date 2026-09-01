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
  # IMPORTANT distinction — a caller in a settings-form view does NOT make a key
  # globally resolved. Views such as app/views/personalization_settings/
  # _form_completed_button_form.html.erb, _form_completed_message_form.html.erb
  # and _form_policy_links_form.html.erb call AccountConfigs.find_for_account
  # only to decide what an admin sees pre-filled in the settings EDITOR. The
  # runtime read — what signers actually get — is elsewhere. For
  # form_completed_button, form_completed_message and policy_links that runtime
  # read is Submitters::FormConfigs (lib/submitters/form_configs.rb), which does
  # a direct per-account query with no fallback:
  #   submitter.submission.account.account_configs.where(key: DEFAULT_KEYS + keys)
  # and all three keys are in DEFAULT_KEYS. So they never resolved globally at
  # runtime, and copying them would inject the lowest-id account's completion
  # message, completion-button URL and policy links into other tenants'
  # signer-facing signing flow. Only a RUNTIME read path through the former
  # global fallback qualifies a key for this list.
  #
  # Each key below is verified read at runtime through that fallback:
  #   submitter_invitation_email     app/mailers/submitter_mailer.rb:27
  #   submitter_completed_email      app/mailers/submitter_mailer.rb:58
  #   submitter_documents_copy_email app/mailers/submitter_mailer.rb:114 and
  #                                  app/jobs/process_submitter_completion_job.rb:134
  #   submitter_reminders            lib/submitters/schedule_reminders.rb:16
  #
  # String literals rather than AccountConfig:: constants so the migration does
  # not depend on application code. The matching constants are named alongside.
  GLOBALLY_RESOLVED_KEYS = [
    'submitter_invitation_email',     # AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY
    'submitter_completed_email',      # AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY
    'submitter_documents_copy_email', # AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY
    'submitter_reminders'             # AccountConfig::SUBMITTER_REMINDERS
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
