# frozen_string_literal: true

# Writes the permanent verification record for a PDF EsignCenter has just
# signed (see VerifiedDocument). Called from the three signing seams — the
# per-submitter document, the combined PDF and the audit trail — with the
# final bytes that were uploaded, so the public /verify page can match an
# upload byte-for-byte. Never rescues: a failed write fails the signing job
# and Sidekiq retries it, because a signed PDF without a record would be
# "not on record" forever.
#
# ORDER MATTERS, and it is the callers' half of the promise: the row is
# written only once the attachment holding those bytes has been SAVED. It
# used to be written straight after signing, before the upload — so an upload
# that failed replaced the row for the copy a signer may already hold with
# the fingerprint of bytes that were never stored, and the delivered PDF
# answered "not on record" on the next retry (review 2, H2). Recorded after
# the save, a row can only ever describe bytes that exist, and a replacement
# can only ever happen because the replacement itself is now stored.
#
# `signed_at` is the moment the last signer completed, not the moment the
# bytes were produced: a combined PDF built lazily at download days later, or
# a signing job retried across midnight, still answers the completion day on
# /verify (the backfill of older documents used completed_at the same way).
#
# One row per OUTPUT (`output_key`), not one per set of bytes. A signing job
# that fails after the PDF is signed is retried, the document is re-signed
# with a new timestamp, and the bytes — and the fingerprint — differ every
# attempt. Keyed on the fingerprint alone, each retry left a permanent extra
# row for a PDF that was never stored and can never be produced again
# (Checkpoint 7, E6-b); keyed per output, the retry replaces its own
# predecessor and every genuine output still keeps its own row. Several rows
# per submission are normal and stay so: one per submitter per document, plus
# the combined PDF and the audit trail.
module VerifiedDocuments
  module_function

  # `output_key` names what was signed, stably across retries:
  # `document:<submitter id>:<document uuid>`,
  # `combined:<submission id>:<audit|merged>` or
  # `audit_trail:<submission id>` — see the three callers.
  def record!(pdf, submission:, kind:, output_key:)
    record_digest!(digest: sha256(pdf), submission:, kind:, output_key:)
  end

  # The same write with the fingerprint already taken. The per-submitter
  # documents are built first and saved together at the end
  # (Submissions::GenerateResultAttachments), so their bytes are fingerprinted
  # while they are in hand and filed once they are stored.
  def record_digest!(digest:, submission:, kind:, output_key:)
    completed = submission.submitters.where.not(completed_at: nil)

    # These exact bytes are already on record under some other output — the
    # same PDF regenerated under a new key, or a row written before outputs
    # were keyed. /verify answers on the fingerprint, so the record already
    # says everything it can say and re-filing it under a second key would
    # only invent a duplicate.
    on_record = VerifiedDocument.find_by(sha256: digest)

    return if on_record && on_record.output_key != output_key

    VerifiedDocument.upsert(
      { sha256: digest,
        signed_at: completed.maximum(:completed_at) || Time.current,
        signers_count: completed.count,
        account_id: submission.account_id,
        submission_id: submission.id,
        kind:,
        output_key: },
      unique_by: :output_key
    )
  end

  # The other half of "one record per output": one FILE per output (review 10,
  # Q1, extending B-F1). An output whose job is retried is signed afresh, the
  # row moves to the new bytes, and the copy the failed attempt saved used to
  # stay attached — `has_one_attached` then served the OLD one, whose
  # fingerprint no longer had a row, so the "Audit Log" button, the API and the
  # export archive all handed out a PDF that /verify answers "not on record"
  # for. The single-attachment outputs (`audit_trail`, `combined_document`,
  # `merged_document`) call this in the same transaction that writes the row,
  # so the record and the retirement are one decision: if the file cannot be
  # deleted the whole thing rolls back and the old row still describes the old
  # copy, which is the honest state, and the job retries.
  #
  # `keep` is the attachment this run just saved; everything else of that name
  # on that record is a predecessor of the same output.
  def retire_superseded_output!(record:, name:, keep:, account_id:)
    superseded = ActiveStorage::Attachment.where(record:, name:).where.not(id: keep.id).to_a

    retire_attachments!(superseded, account_id:,
                                    subject: "Could not delete a superseded #{name.tr('_', ' ')}")

    association = :"#{name}_attachment"
    record.association(association).reset if record.class.reflect_on_association(association)

    superseded
  end

  # Storage-first, through the same helper an expiring export uses: the object
  # goes, it is verified gone, and only then the rows that name it —
  # `ActiveStorage::Blob#purge` is the other way round and would leave the
  # signed PDF in the bucket with nothing left anywhere able to find it.
  def retire_attachments!(attachments, account_id:, subject:)
    attachments.each do |attachment|
      Accounts::Purge.purge_blob_storage_first!(attachment.blob, account_id:, subject:)
    end
  end

  def sha256(pdf)
    bytes =
      if pdf.respond_to?(:string)
        pdf.string
      elsif pdf.respond_to?(:read)
        pdf.rewind if pdf.respond_to?(:rewind)
        pdf.read
      else
        pdf
      end

    Digest::SHA256.hexdigest(bytes)
  end
end
