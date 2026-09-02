# frozen_string_literal: true

class BackfillVerifiedDocuments < ActiveRecord::Migration[8.1]
  # Every signed document completed before the public /verify page existed is
  # already fingerprinted in completed_documents (urlsafe-base64 SHA-256 of the
  # signed PDF bytes, one row per submitter). Copy those fingerprints into
  # verified_documents as hex so the public page can answer for them: the
  # signing date is the submitter's completion time and the signer count is
  # the submitters who had completed by this submitter's completion time (what
  # the signing job saw when it produced this PDF: under the `multiple` signing
  # preference the first signer's PDF is generated when they finish and never
  # regenerated, so it records 1, the second signer's 2). Ties count: a peer
  # with an equal completed_at is included, as the live path counts everyone
  # completed by the time the signing job runs — and the row's own submitter is
  # always included. Rows whose submitter is already gone carry no date and are
  # skipped; a fingerprint that does not decode to 32 bytes is skipped too.
  # Combined and audit-trail PDFs were never fingerprinted, so pre-existing
  # ones stay "not on record" (docs/verify.md).
  BATCH_SIZE = 1000

  class VerifiedDocumentRow < ActiveRecord::Base
    self.table_name = 'verified_documents'
  end

  def up
    last_id = 0

    loop do
      rows = select_all(batch_sql(last_id)).to_a

      break if rows.empty?

      last_id = rows.last['id']
      attributes = build_rows(rows)

      VerifiedDocumentRow.insert_all(attributes, unique_by: :sha256) if attributes.any?
    end
  end

  def down
    # Nothing to undo: the rows are the permanent verification record and are
    # harmless without the page (they hold no identities).
  end

  private

  def batch_sql(last_id)
    <<~SQL.squish
      SELECT completed_documents.id,
             completed_documents.sha256,
             submitters.completed_at,
             submitters.submission_id,
             submitters.account_id,
             (SELECT COUNT(*) FROM submitters AS peers
              WHERE peers.submission_id = submitters.submission_id
                AND peers.completed_at IS NOT NULL
                AND peers.completed_at <= submitters.completed_at) AS signers_count
      FROM completed_documents
        INNER JOIN submitters ON submitters.id = completed_documents.submitter_id
      WHERE completed_documents.id > #{last_id.to_i}
        AND submitters.completed_at IS NOT NULL
      ORDER BY completed_documents.id
      LIMIT #{BATCH_SIZE}
    SQL
  end

  def build_rows(rows)
    now = Time.current

    attributes = rows.filter_map do |row|
      hex = hex_sha256(row['sha256'])

      next unless hex

      { sha256: hex,
        signed_at: row['completed_at'],
        signers_count: row['signers_count'],
        account_id: row['account_id'],
        submission_id: row['submission_id'],
        kind: 'document',
        created_at: now,
        updated_at: now }
    end

    attributes.uniq { |row| row[:sha256] }
  end

  def hex_sha256(urlsafe_base64)
    digest = Base64.urlsafe_decode64(urlsafe_base64.to_s)

    digest.bytesize == 32 ? digest.unpack1('H*') : nil
  rescue ArgumentError
    nil
  end
end
