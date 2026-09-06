# frozen_string_literal: true

# One verification record per signed OUTPUT, not one per set of bytes.
#
# `verified_documents` was keyed on the SHA-256 of the bytes alone, which is
# the right key for reading (/verify matches an uploaded file byte for byte)
# and the wrong one for writing. A signing job that fails after `pdf.sign` —
# a storage upload, a later submitter, the combined or audit-trail seam — is
# retried by Sidekiq, the PDF is re-signed with a NEW timestamp, and the new
# bytes hash differently: every attempt added a fresh permanent row for a PDF
# that was never stored and that nobody can ever produce again (Checkpoint 7,
# E6-b). These rows survive account and submission purge forever (D43), so
# they are not garbage that ages out.
#
# `output_key` names the thing being signed — this submitter's copy of this
# document, this submission's combined PDF, this submission's audit trail —
# so a retry REPLACES its own predecessor and every real output still keeps
# its own row.
#
# Reversible and safe on existing data: the column is added empty, and NULLs
# do not collide in a Postgres unique index, so no existing row can violate
# it. Rows written before this migration keep a NULL key and are left exactly
# as they are — a fingerprint already on record still answers /verify.
#
# The index is built CONCURRENTLY for the same reason as the submitters one
# (20260906090000): `verified_documents` grows by a row per signed output and
# never shrinks — the rows outlive the account — so on a live install this is
# not a small table, and an ordinary build would hold a SHARE lock on it for
# the duration. `if_not_exists` makes the step re-runnable after a failed
# concurrent build, which leaves an INVALID index behind.
class AddOutputKeyToVerifiedDocuments < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :verified_documents, :output_key, :string, if_not_exists: true

    add_index :verified_documents, :output_key, unique: true, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :verified_documents, :output_key, algorithm: :concurrently, if_exists: true

    remove_column :verified_documents, :output_key, if_exists: true
  end
end
