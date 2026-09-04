# frozen_string_literal: true

# Deleting an account is a 90-day decision (D43), and these four columns are
# the whole of it:
#
#   deletion_requested_at    — when an admin asked. Also what the Danger Zone
#                              card and the dashboard banner read.
#   purge_scheduled_for      — the date everything is destroyed. Indexed
#                              (partially, on the rows still waiting) because
#                              the nightly sweep asks "whose date has passed?"
#                              against every account there is.
#   purged_at                — stamped when the purge finished, so the account
#                              row survives as a tombstone and a second run of
#                              the same purge is a no-op.
#   deletion_requested_by_id — who asked, for the audit trail. Nullified on
#                              delete rather than blocking, because the purge
#                              deletes the account's users and this column
#                              must not be what stops it.
#
# One ALTER for the four columns (`bulk: true`): four separate ones would each
# take their own lock on a table every request in the app reads.
class AddDeletionToAccounts < ActiveRecord::Migration[8.1]
  def change
    change_table :accounts, bulk: true do |t|
      t.datetime :deletion_requested_at
      t.datetime :purge_scheduled_for
      t.datetime :purged_at
      t.bigint :deletion_requested_by_id
    end

    add_index :accounts, :deletion_requested_by_id
    add_foreign_key :accounts, :users, column: :deletion_requested_by_id, on_delete: :nullify

    add_index :accounts, :purge_scheduled_for, where: 'purge_scheduled_for IS NOT NULL AND purged_at IS NULL',
                                               name: 'index_accounts_on_pending_purge'
  end
end
