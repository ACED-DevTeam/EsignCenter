# frozen_string_literal: true

# Writes the permanent verification record for a PDF EsignCenter has just
# signed (see VerifiedDocument). Called from the three signing seams — the
# per-submitter document, the combined PDF and the audit trail — with the
# final bytes that were uploaded, so the public /verify page can match an
# upload byte-for-byte. Never rescues: a failed write fails the signing job
# and Sidekiq retries it, because a signed PDF without a record would be
# "not on record" forever.
module VerifiedDocuments
  module_function

  def record!(pdf, submission:, kind:)
    VerifiedDocument.upsert(
      { sha256: sha256(pdf),
        signed_at: Time.current,
        signers_count: submission.submitters.where.not(completed_at: nil).count,
        account_id: submission.account_id,
        submission_id: submission.id,
        kind: },
      unique_by: :sha256
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
