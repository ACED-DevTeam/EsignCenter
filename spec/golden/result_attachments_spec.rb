# frozen_string_literal: true

# Two things that only show up when a signing job is asked to do its work
# twice, or asked to draw a value that names nothing.
#
# 1. `verified_documents` is keyed per OUTPUT, not per set of bytes (E6-b).
#    Every attempt at signing produces different bytes, because the timestamp
#    inside the signature differs, so a job retried after a storage or TSA
#    failure used to leave a permanent extra row for a PDF that was never
#    stored and can never be produced again. These rows survive account and
#    submission purge forever (D43), so they do not age out.
#
# 2. A field whose value names no attachment of this submitter no longer
#    takes the whole completion down. It used to raise
#    `undefined method 'uuid' for nil` inside GenerateResultAttachments, and
#    because Submissions::EnsureResultGenerated replays the same data on every
#    attempt, the customer's signed PDF was unreachable forever.
RSpec.describe 'Signed result attachments', type: :request do
  let!(:account) { create(:account) }
  let(:admin) { @admin ||= create(:user, :admin, account:) }

  def template_for(account, only_field_types: %w[text])
    create(:template, account:, author: admin, only_field_types:)
  end

  def completed_submitter(template: template_for(account))
    submission = create(:submission, :with_submitters, template:, created_by_user: admin)
    submitter = submission.submitters.first

    submitter.update!(sent_at: Time.current, email: 'jane@example.com', name: 'Jane Signer',
                      completed_at: Time.current,
                      values: template.fields.to_h { |f| [f['uuid'], 'Jane'] })

    submitter
  end

  describe 'one verification record per output (E6-b)' do
    it 'replaces the row when the same output is signed again with different bytes' do
      submitter = completed_submitter
      submission = submitter.submission
      key = "document:#{submitter.id}:doc-1"

      VerifiedDocuments.record!('first attempt', submission:, kind: 'document', output_key: key)
      VerifiedDocuments.record!('second attempt', submission:, kind: 'document', output_key: key)

      rows = VerifiedDocument.where(output_key: key)

      expect(rows.count).to eq(1)
      expect(rows.sole.sha256).to eq(VerifiedDocuments.sha256('second attempt'))
      expect(VerifiedDocument.where(sha256: VerifiedDocuments.sha256('first attempt'))).not_to exist
    end

    it 'keeps a row of its own for every real output of one submission' do
      submitter = completed_submitter
      submission = submitter.submission

      %W[document:#{submitter.id}:doc-1 document:#{submitter.id}:doc-2
         combined:#{submission.id}:audit audit_trail:#{submission.id}].each_with_index do |key, index|
        VerifiedDocuments.record!("bytes #{index}", submission:, kind: 'document', output_key: key)
      end

      expect(VerifiedDocument.where(submission_id: submission.id).count).to eq(4)
    end

    it 'leaves bytes already on record alone rather than filing them twice' do
      submitter = completed_submitter
      submission = submitter.submission

      VerifiedDocuments.record!('same bytes', submission:, kind: 'document',
                                              output_key: "document:#{submitter.id}:doc-1")
      VerifiedDocuments.record!('same bytes', submission:, kind: 'combined',
                                              output_key: "combined:#{submission.id}:audit")

      row = VerifiedDocument.where(sha256: VerifiedDocuments.sha256('same bytes')).sole

      expect(row.output_key).to eq("document:#{submitter.id}:doc-1")
      expect(row.kind).to eq('document')
    end

    # The real shape of the bug: a completion that gets as far as signing and
    # then fails, retried by Sidekiq. Each attempt signs afresh, so the bytes
    # (and their fingerprint) differ every time.
    it 'adds nothing when a signing job is retried after signing succeeded', sidekiq: :inline do
      platform_certificate!

      submitter = completed_submitter

      Submissions::GenerateResultAttachments.call(submitter)

      after_first = VerifiedDocument.where(submission_id: submitter.submission_id).pluck(:sha256, :output_key)

      expect(after_first.size).to eq(1)

      travel_to(2.minutes.from_now) { Submissions::GenerateResultAttachments.call(submitter.reload) }

      after_retry = VerifiedDocument.where(submission_id: submitter.submission_id).pluck(:sha256, :output_key)

      expect(after_retry.size).to eq(1)
      expect(after_retry.first.last).to eq(after_first.first.last)
      expect(after_retry.first.first).not_to eq(after_first.first.first)
    end

    # The other half of that promise (review 2, H2). The row used to be
    # written straight after signing and BEFORE the upload, so a retry that
    # died on the way to storage replaced the fingerprint of the PDF the
    # signer already holds with one for bytes that were never stored — the
    # delivered document then answered "not on record" for ever. Nothing is
    # filed until the attachment is saved.
    it 'keeps the stored document verifiable when a retry dies before the new bytes are stored',
       sidekiq: :inline do
      platform_certificate!

      submitter = completed_submitter

      Submissions::GenerateResultAttachments.call(submitter)

      delivered_sha = VerifiedDocument.where(submission_id: submitter.submission_id).sole.sha256

      allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_raise(Errno::ECONNREFUSED)

      expect do
        travel_to(2.minutes.from_now) { Submissions::GenerateResultAttachments.call(submitter.reload) }
      end.to raise_error(Errno::ECONNREFUSED)

      rows = VerifiedDocument.where(submission_id: submitter.submission_id)

      expect(rows.count).to eq(1)
      expect(rows.sole.sha256).to eq(delivered_sha)

      # Said the way a signer would ask it: the bytes actually in storage are
      # the bytes on record.
      stored = submitter.documents.reload.sole

      expect(Digest::SHA256.hexdigest(stored.download)).to eq(delivered_sha)
    end
  end

  # A retry does not only replace a ROW. It replaces the customer's document,
  # and the copy it replaces used to stay attached: the completion mail
  # carried two sealed PDFs, `/s/:slug/download` served two, and the older one
  # answered "not on record" at /verify because `verified_documents` is keyed
  # per output and the row had moved to the new bytes (review 10, B-F1).
  describe 'a retried signing job leaves exactly one copy' do
    def download_digests(submitter)
      Submitters.select_attachments_for_download(submitter).map { |a| Digest::SHA256.hexdigest(a.download) }
    end

    it 'retires the superseded document and its file', sidekiq: :inline do
      platform_certificate!

      submitter = completed_submitter
      schema_documents = submitter.submission.template_schema.size

      Submissions::GenerateResultAttachments.call(submitter)

      superseded = submitter.documents.reload.sole
      blob = superseded.blob
      key = blob.key
      service = blob.service

      travel_to(2.minutes.from_now) { Submissions::GenerateResultAttachments.call(submitter.reload) }

      documents = submitter.documents.reload

      # One per schema document, and the one that is left is the new one.
      expect(documents.size).to eq(schema_documents)
      expect(documents.map { |a| a.metadata['original_uuid'] }.uniq.size).to eq(schema_documents)
      expect(documents.map(&:id)).not_to include(superseded.id)

      # Said the way a signer asks it: every file the download door hands out
      # is a file /verify can answer for.
      digests = download_digests(submitter.reload)

      expect(digests.size).to eq(schema_documents)
      digests.each { |digest| expect(VerifiedDocument.where(sha256: digest)).to exist }

      # The retired copy is gone from the database AND from storage.
      expect(ActiveStorage::Attachment.where(id: superseded.id)).not_to exist
      expect(ActiveStorage::Blob.where(id: blob.id)).not_to exist
      expect(service.exist?(key)).to be(false)
    end

    # The same thing through the door every download goes through. An attempt
    # that saved its attachments and then died writes a `fail` lock event, and
    # the next call regenerates rather than waiting.
    it 'leaves one copy when EnsureResultGenerated regenerates after a failed attempt', sidekiq: :inline do
      platform_certificate!

      submitter = completed_submitter
      lock_key = ['result_attachments', submitter.id].join(':')

      allow(ErrorReport).to receive(:error)
      allow(VerifiedDocuments).to receive(:record_digest!).and_raise(Errno::ECONNREFUSED)

      expect { Submissions::EnsureResultGenerated.call(submitter) }.to raise_error(Errno::ECONNREFUSED)

      superseded = submitter.documents.reload.sole

      expect(LockEvent.where(key: lock_key, event_name: 'fail')).to exist

      allow(VerifiedDocuments).to receive(:record_digest!).and_call_original

      travel_to(2.minutes.from_now) { Submissions::EnsureResultGenerated.call(submitter.reload) }

      documents = submitter.documents.reload

      expect(documents.size).to eq(1)
      expect(documents.map(&:id)).not_to include(superseded.id)
      expect(ActiveStorage::Blob.where(id: superseded.blob_id)).not_to exist

      digests = download_digests(submitter.reload)

      expect(digests.size).to eq(1)
      digests.each { |digest| expect(VerifiedDocument.where(sha256: digest)).to exist }
    end
  end

  describe 'a field whose value names no attachment' do
    # The API takes any value a caller sends for any field, so a signature
    # field can end up holding a string that was never an upload.
    def signature_submitter_with_dangling_value
      template = template_for(account, only_field_types: %w[signature])
      submission = create(:submission, :with_submitters, template:, created_by_user: admin)
      submitter = submission.submitters.first
      field = template.fields.find { |f| f['type'] == 'signature' }

      submitter.update!(sent_at: Time.current, email: 'jane@example.com', completed_at: Time.current,
                        values: { field['uuid'] => 'not-an-attachment-uuid' })

      submitter
    end

    it 'still produces the document, and reports the field instead of raising' do
      platform_certificate!
      submitter = signature_submitter_with_dangling_value

      allow(ErrorReport).to receive(:warning)

      documents = Submissions::GenerateResultAttachments.call(submitter)

      expect(ErrorReport).to have_received(:warning)
        .with(/Missing attachment for field #{submitter.id}/).at_least(:once)
      expect(documents).to be_present
      expect(documents.map(&:name)).to all(eq('documents'))
    end

    # EnsureResultGenerated is the door every download goes through. Before
    # this it raised, wrote a `fail` lock event, and did it again on the next
    # attempt — the signed PDF was unreachable for good.
    it 'lets Submissions::EnsureResultGenerated finish instead of failing forever' do
      platform_certificate!
      submitter = signature_submitter_with_dangling_value

      allow(ErrorReport).to receive(:warning)

      documents = Submissions::EnsureResultGenerated.call(submitter)

      expect(documents).to be_present
      expect(LockEvent.where(key: ['result_attachments', submitter.id].join(':'), event_name: 'fail')).not_to exist
      expect(LockEvent.where(key: ['result_attachments', submitter.id].join(':'), event_name: 'complete')).to exist
    end
  end
end
