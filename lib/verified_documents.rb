# frozen_string_literal: true

# Writes the permanent verification record for a PDF EsignCenter has just
# signed (see VerifiedDocument). Called from the three signing seams — the
# per-submitter document, the combined PDF and the audit trail — with the
# final bytes that were uploaded, so the public /verify page can match an
# upload byte-for-byte. Never rescues: a failed write fails the signing job
# and Sidekiq retries it, because a signed PDF without a record would be
# "not on record" forever.
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
    digest = sha256(pdf)
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
