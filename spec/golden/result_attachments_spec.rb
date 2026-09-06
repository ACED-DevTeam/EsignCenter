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
