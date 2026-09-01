# frozen_string_literal: true

# Repairs databases that ran the ORIGINAL version of 20260901090300, which
# copied EVERY one of the lowest-id account's account_configs rows into every
# other pre-existing account. Only the keys listed below were ever resolved
# globally (the fallback lived in AccountConfigs.find_for_account); every other
# key was read per-account and never fell back. So the extra rows are not
# behavior preservation — they silently impose the lowest-id account's settings
# on other tenants, and for 'bcc_emails' they cause completed documents from
# other tenants to be BCC'd to the lowest-id account's recipients.
#
# This migration must be a no-op on any database that never ran the original
# (production has not), and must never remove a value an operator set. It
# therefore deletes only rows that carry the buggy backfill's full fingerprint.
class CleanupOverCopiedAccountConfigs < ActiveRecord::Migration[8.1]
  # Same allowlist as the corrected 20260901090300 — the two must stay identical
  # (a spec asserts it). String literals so the migration does not depend on
  # application code; constants named alongside.
  #
  # A caller in a settings-form view does NOT make a key globally resolved: the
  # personalization settings partials only decide what an admin sees pre-filled
  # in the settings EDITOR. Only a runtime read path through the former global
  # fallback in AccountConfigs.find_for_account qualifies. That is why
  # form_completed_button, form_completed_message and policy_links are absent
  # (and therefore deletable): their runtime read is Submitters::FormConfigs,
  # a direct per-account query with no fallback, so copies of them are not
  # behavior preservation — they inject the lowest-id account's completion
  # message, completion-button URL and policy links into other tenants'
  # signer-facing signing flow.
  GLOBALLY_RESOLVED_KEYS = [
    'submitter_invitation_email',     # AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY
    'submitter_completed_email',      # AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY
    'submitter_documents_copy_email', # AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY
    'submitter_reminders'             # AccountConfig::SUBMITTER_REMINDERS
  ].freeze

  # AccountConfig::BCC_EMAILS — the single key exempted from the batch-sibling
  # requirement below, because its stale copy leaks documents across tenants.
  BCC_EMAILS_KEY = 'bcc_emails'

  def up
    return if select_value('SELECT COUNT(*) FROM accounts').to_i <= 1

    ids = select_values(over_copied_ids_sql).map(&:to_i)

    say "removing #{ids.size} over-copied account_configs row(s)"

    return if ids.empty?

    ids.each_slice(1_000) do |slice|
      execute("DELETE FROM account_configs WHERE id IN (#{slice.join(', ')})")
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # A row is deleted only when every one of these holds (SQL comments are
  # omitted from the statement itself because .squish collapses newlines):
  #
  # 1. victims.account_id <> MIN(accounts.id) — never touch the source account;
  #    the lowest-id account's own rows are the originals, not copies.
  # 2. victims.key NOT IN (allowlist) — the allowlisted keys were genuinely
  #    resolved globally before the change, so copies of them are the intended
  #    behavior preservation and must stay.
  # 3. victims.created_at = victims.updated_at — the row has never been edited
  #    since it was written, so no operator has touched it.
  # 4. an identical row exists on the lowest-id account (same key, byte-identical
  #    value) — a row whose value differs from the source cannot be a copy of it.
  # 5. (extra safety, beyond the four above) the row carries the buggy INSERT's
  #    batch fingerprint: another never-edited exact copy of a lowest-id-account
  #    value, on a non-lowest account, shares its created_at to the microsecond.
  #    The buggy INSERT stamped every row it wrote with one CURRENT_TIMESTAMP, so
  #    real backfill rows always have such a sibling. Without this clause the
  #    migration would not be a no-op on a database that never ran the original:
  #    a tenant that legitimately set a boolean toggle (say force_mfa = true) to
  #    the same value the lowest-id account uses, and never edited it again,
  #    satisfies 1-4 and would have its real setting deleted. Timestamp
  #    collisions to the microsecond across separate operator edits do not
  #    happen, so this clause admits backfill rows and nothing else. Trade-off:
  #    if the original backfill wrote exactly one row on the whole database, that
  #    lone row has no sibling — see the bcc_emails exemption below.
  #
  # Exemption to 5, for 'bcc_emails' ONLY: that key is deleted on conditions 1-4
  # alone, with no sibling required. It is the one key whose stale copy causes
  # cross-tenant document delivery — ProcessSubmitterCompletionJob#build_bcc_addresses
  # reads it and SubmitterMailer.completed_email attaches the completed documents
  # and the audit log — so a lone copy left behind by a one-row backfill would
  # keep leaking. A false-positive deletion here is harmless: it merely stops a
  # BCC that duplicated the lowest-id account's address, which an operator can
  # re-set in seconds. It is not a security setting whose silent removal weakens
  # anything. Every other non-allowlisted key keeps the sibling requirement,
  # where a false positive WOULD silently weaken a real setting (e.g. force_mfa).
  def over_copied_ids_sql
    allowed_keys = GLOBALLY_RESOLVED_KEYS.map { |key| quote(key) }.join(', ')
    leaky_key = quote(BCC_EMAILS_KEY)

    <<~SQL.squish
      SELECT victims.id
      FROM account_configs AS victims
      WHERE victims.account_id <> (SELECT MIN(id) FROM accounts)
        AND victims.key NOT IN (#{allowed_keys})
        AND victims.created_at = victims.updated_at
        AND EXISTS (
          SELECT 1
          FROM account_configs AS source
          WHERE source.account_id = (SELECT MIN(id) FROM accounts)
            AND source.key = victims.key
            AND source.value = victims.value
        )
        AND (
          victims.key = #{leaky_key}
          OR EXISTS (
            SELECT 1
            FROM account_configs AS batch_sibling
            WHERE batch_sibling.id <> victims.id
              AND batch_sibling.created_at = victims.created_at
              AND batch_sibling.created_at = batch_sibling.updated_at
              AND batch_sibling.account_id <> (SELECT MIN(id) FROM accounts)
              AND EXISTS (
                SELECT 1
                FROM account_configs AS sibling_source
                WHERE sibling_source.account_id = (SELECT MIN(id) FROM accounts)
                  AND sibling_source.key = batch_sibling.key
                  AND sibling_source.value = batch_sibling.value
              )
          )
        )
    SQL
  end
end
