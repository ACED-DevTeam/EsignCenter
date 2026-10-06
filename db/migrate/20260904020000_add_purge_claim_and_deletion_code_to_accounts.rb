# frozen_string_literal: true

# Two things the deletion flow has to write down rather than derive (review
# batch 2 loop 2, P1 and P5).
#
# THE PURGE CLAIM (`purge_started_at`). The purge used to run inside one
# transaction holding the account's row lock across storage I/O: a failure at
# the end rolled the row deletes back while the files were already gone, and
# every "Cancel deletion" waited for the whole thing. Now the lock is held only
# long enough to re-check eligibility and stamp this column; the purge itself
# runs outside the transaction and is idempotent. Once the claim is set the
# account is committed to deletion — sign-in stops, cancellation is refused,
# and a run that fails leaves the claim in place so the next one resumes.
#
# THE CONFIRMATION CODE. It was a TOTP derived from the server secret, which
# meant every 15-minute window had a valid code whether or not one had ever
# been emailed, the same code stayed valid after it was used, and the attempt
# budget lived in Redis — so an unreachable Redis failed OPEN. A stored code
# fixes all three: one code at a time, hashed so the database does not hold
# it, consumed on success, and counted in a column that cannot fail open.
class AddPurgeClaimAndDeletionCodeToAccounts < ActiveRecord::Migration[8.1]
  def change
    change_table :accounts, bulk: true do |t|
      t.datetime :purge_started_at
      t.string :deletion_code_digest
      t.datetime :deletion_code_expires_at
      t.integer :deletion_code_attempts, null: false, default: 0
      t.bigint :deletion_code_user_id
    end
  end
end
