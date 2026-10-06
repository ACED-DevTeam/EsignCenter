# frozen_string_literal: true

require Rails.root.join('db/migrate/20260901090300_backfill_account_configs.rb')
require Rails.root.join('db/migrate/20260901090500_cleanup_over_copied_account_configs.rb')

# The de-globalization backfill may only copy the keys that were genuinely
# resolved globally before the change (the fallback lived in
# AccountConfigs.find_for_account). Every other key was read per-account and
# never fell back — copying it would newly impose the lowest-id account's
# settings on other tenants, and for 'bcc_emails' it would BCC other tenants'
# completed documents to the lowest-id account's recipients.
#
# A caller in a settings-form view does NOT make a key globally resolved: the
# personalization settings partials only pre-fill the admin's settings editor.
# form_completed_button, form_completed_message and policy_links are read at
# RUNTIME by Submitters::FormConfigs, a direct per-account query with no
# fallback, so copying them would inject the lowest-id account's completion
# message, completion-button URL and policy links into other tenants'
# signer-facing signing flow.
RSpec.describe BackfillAccountConfigs do
  # The lowest-id account is the one the pre-change global fallback pointed at.
  let!(:source_account) { create(:account) }
  let!(:other_account) { create(:account) }

  let(:completed_email_value) { { 'subject' => 'Source subject', 'body' => 'Source body' } }

  def run_backfill
    ActiveRecord::Migration.suppress_messages { BackfillAccountConfigs.new.up }
  end

  def run_cleanup
    ActiveRecord::Migration.suppress_messages { CleanupOverCopiedAccountConfigs.new.up }
  end

  # The 20260901090300 migration EXACTLY as it was originally written (it copied
  # every key). Used only to reproduce the damaged state a dev database is in,
  # so the cleanup migration is exercised against realistic rows rather than
  # hand-placed ones. Never used as the subject under test.
  def run_original_buggy_backfill
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
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
        AND NOT EXISTS (
          SELECT 1
          FROM account_linked_accounts AS links
          WHERE links.linked_account_id = target_accounts.id
            AND links.account_type = 'testing'
        )
    SQL
  end

  # The three keys whose only find_for_account callers are settings-form views;
  # their runtime read is Submitters::FormConfigs, which never falls back.
  def create_signer_facing_source_configs
    create(:account_config, account: source_account,
                            key: AccountConfig::FORM_COMPLETED_BUTTON_KEY,
                            value: { 'title' => 'Back to source', 'url' => 'https://source.example' })
    create(:account_config, account: source_account,
                            key: AccountConfig::FORM_COMPLETED_MESSAGE_KEY,
                            value: { 'title' => 'Thanks', 'body' => 'From the source tenant' })
  end

  before do
    # Globally resolved before the change — must be copied.
    create(:account_config, account: source_account,
                            key: AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY,
                            value: completed_email_value)

    # Read at runtime per-account by Submitters::FormConfigs (policy_links is in
    # its DEFAULT_KEYS) — the settings-view caller only pre-fills the editor, so
    # this key never resolved globally at runtime and must NOT be copied.
    create(:account_config, account: source_account,
                            key: AccountConfig::POLICY_LINKS_KEY,
                            value: [{ 'title' => 'Terms', 'url' => 'https://source.example/terms' }])

    # Never globally resolved — must NOT be copied. bcc_emails is the leak:
    # ProcessSubmitterCompletionJob reads submitter.account's own row.
    create(:account_config, account: source_account,
                            key: AccountConfig::BCC_EMAILS,
                            value: 'audit@source-tenant.example')
    create(:account_config, account: source_account,
                            key: AccountConfig::FORCE_MFA,
                            value: true)

    # Globally resolved by a second, independent read — the unscoped
    # AccountConfig.where(key:).first_or_initialize in fetch_sign_reason — so
    # the lowest-id account's row decided every tenant's PDF signature Reason
    # format. Must be copied.
    create(:account_config, account: source_account,
                            key: AccountConfig::ESIGNING_PREFERENCE_KEY,
                            value: 'multiple')
  end

  it 'keeps the two migrations allowlists identical' do
    expect(BackfillAccountConfigs::GLOBALLY_RESOLVED_KEYS)
      .to eq(CleanupOverCopiedAccountConfigs::GLOBALLY_RESOLVED_KEYS)
  end

  it 'allowlists exactly the keys that were read globally at runtime' do
    expect(BackfillAccountConfigs::GLOBALLY_RESOLVED_KEYS).to contain_exactly(
      AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
      AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY,
      AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY,
      AccountConfig::SUBMITTER_REMINDERS,
      AccountConfig::ESIGNING_PREFERENCE_KEY
    )
  end

  describe 'the corrected backfill' do
    it 'treats the first created account as the pre-change global fallback source' do
      expect(Account.minimum(:id)).to eq(source_account.id)
    end

    it 'never copies the signer-facing form keys read per-account by FormConfigs' do
      create_signer_facing_source_configs

      run_backfill

      signer_facing_keys = [AccountConfig::FORM_COMPLETED_BUTTON_KEY,
                            AccountConfig::FORM_COMPLETED_MESSAGE_KEY,
                            AccountConfig::POLICY_LINKS_KEY]

      expect(other_account.account_configs.pluck(:key)).not_to include(*signer_facing_keys)
      expect(AccountConfig.where(key: signer_facing_keys).pluck(:account_id).uniq)
        .to eq([source_account.id])
      expect(BackfillAccountConfigs::GLOBALLY_RESOLVED_KEYS).not_to include(*signer_facing_keys)
    end

    it 'never copies bcc_emails to another tenant' do
      run_backfill

      expect(other_account.account_configs.find_by(key: AccountConfig::BCC_EMAILS)).to be_nil
      expect(AccountConfig.where(key: AccountConfig::BCC_EMAILS).pluck(:account_id))
        .to eq([source_account.id])
    end

    it 'copies no key that was read per-account before the change' do
      run_backfill

      copied_keys = other_account.account_configs.pluck(:key)

      expect(copied_keys).to match_array(BackfillAccountConfigs::GLOBALLY_RESOLVED_KEYS &
                                         source_account.account_configs.pluck(:key))
      expect(copied_keys).to contain_exactly(AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY,
                                             AccountConfig::ESIGNING_PREFERENCE_KEY)
      expect(copied_keys).not_to include(AccountConfig::BCC_EMAILS, AccountConfig::FORCE_MFA)
    end

    it 'copies esigning_preference so the signature Reason format is preserved' do
      run_backfill

      copied = other_account.account_configs.find_by(key: AccountConfig::ESIGNING_PREFERENCE_KEY)

      expect(copied).to be_present
      expect(copied.value).to eq('multiple')
      expect(AccountConfigs.find_for_account(other_account, AccountConfig::ESIGNING_PREFERENCE_KEY))
        .to eq(copied)
    end

    it 'still copies the globally resolved template keys so behavior is preserved' do
      run_backfill

      copied = other_account.account_configs.find_by(key: AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY)

      expect(copied).to be_present
      expect(copied.value).to eq(completed_email_value)
      expect(AccountConfigs.find_for_account(other_account, AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY))
        .to eq(copied)
    end

    it 'leaves an account own value alone and skips testing accounts' do
      own_value = { 'subject' => 'Own subject', 'body' => 'Own body' }
      create(:account_config, account: other_account,
                              key: AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY, value: own_value)
      testing_child = create(:account)
      source_account.testing_accounts << testing_child

      run_backfill

      expect(other_account.account_configs.find_by(key: AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY).value)
        .to eq(own_value)
      expect(testing_child.reload.account_configs).to be_empty
    end
  end

  describe CleanupOverCopiedAccountConfigs do
    it 'removes rows the original migration over-copied and keeps the allowlisted ones' do
      run_original_buggy_backfill

      expect(other_account.account_configs.pluck(:key)).to include(AccountConfig::BCC_EMAILS)

      run_cleanup

      expect(other_account.account_configs.find_by(key: AccountConfig::BCC_EMAILS)).to be_nil
      expect(other_account.account_configs.find_by(key: AccountConfig::FORCE_MFA)).to be_nil
      expect(other_account.account_configs.find_by(key: AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY).value)
        .to eq(completed_email_value)
      # policy_links is no longer allowlisted — its runtime read is FormConfigs,
      # so an over-copied row is signer-facing pollution and must be removed.
      expect(other_account.account_configs.find_by(key: AccountConfig::POLICY_LINKS_KEY)).to be_nil
      expect(other_account.account_configs.find_by(key: AccountConfig::ESIGNING_PREFERENCE_KEY).value)
        .to eq('multiple')
      expect(source_account.account_configs.pluck(:key)).to contain_exactly(
        AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY, AccountConfig::POLICY_LINKS_KEY,
        AccountConfig::BCC_EMAILS, AccountConfig::FORCE_MFA, AccountConfig::ESIGNING_PREFERENCE_KEY
      )
    end

    it 'removes over-copied signer-facing form keys' do
      create_signer_facing_source_configs

      run_original_buggy_backfill

      signer_facing_keys = [AccountConfig::FORM_COMPLETED_BUTTON_KEY,
                            AccountConfig::FORM_COMPLETED_MESSAGE_KEY,
                            AccountConfig::POLICY_LINKS_KEY]

      expect(other_account.account_configs.pluck(:key)).to include(*signer_facing_keys)

      run_cleanup

      expect(other_account.reload.account_configs.pluck(:key)).not_to include(*signer_facing_keys)
      expect(source_account.account_configs.pluck(:key)).to include(*signer_facing_keys)
    end

    it 'keeps a lone identical bcc_emails row that has no batch sibling' do
      # Production never ran the original backfill. A second internal account
      # that legitimately BCCs the same mailbox as the lowest-id account, set
      # once and never edited, satisfies every condition except the batch
      # fingerprint — it is a real setting and must survive. (A one-row
      # original backfill would leave such a row on the dev database only,
      # and dev is reset rather than repaired.)
      lone_row = create(:account_config, account: other_account,
                                         key: AccountConfig::BCC_EMAILS,
                                         value: 'audit@source-tenant.example')

      expect { run_cleanup }.not_to change(AccountConfig, :count)
      expect(lone_row.reload.value).to eq('audit@source-tenant.example')
    end

    it 'keeps a lone non-bcc row that has no batch sibling' do
      # The production-safety guard: on a database that never ran the original
      # migration, a real operator setting that happens to match the source
      # account must survive.
      lone_row = create(:account_config, account: other_account,
                                         key: AccountConfig::FORCE_MFA, value: true)

      expect { run_cleanup }.not_to change(AccountConfig, :count)
      expect(lone_row.reload.value).to be(true)
    end

    it 'is a no-op on a database that only ever ran the corrected backfill' do
      # An operator-set toggle that happens to match the source account exactly
      # and was never edited afterwards — it satisfies every condition except
      # the backfill batch fingerprint, so it must survive.
      operator_row = create(:account_config, account: other_account,
                                             key: AccountConfig::FORCE_MFA, value: true)

      run_backfill

      expect { run_cleanup }.not_to change(AccountConfig, :count)
      expect(operator_row.reload.value).to be(true)
    end

    it 'keeps a row an operator edited and a row whose value differs from the source' do
      edited = create(:account_config, account: other_account, key: AccountConfig::FORCE_MFA, value: true)
      edited.update_column(:updated_at, edited.updated_at + 1.minute)
      divergent = create(:account_config, account: other_account,
                                          key: AccountConfig::BCC_EMAILS,
                                          value: 'audit@other-tenant.example')

      run_original_buggy_backfill
      run_cleanup

      expect(edited.reload.value).to be(true)
      expect(divergent.reload.value).to eq('audit@other-tenant.example')
    end
  end
end
