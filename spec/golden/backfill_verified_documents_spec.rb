# frozen_string_literal: true

require Rails.root.join('db/migrate/20260902100100_backfill_verified_documents.rb')

# Documents signed before the public /verify page existed must still verify:
# completed_documents already holds the urlsafe-base64 SHA-256 of every signed
# per-submitter PDF, so the backfill copies it into verified_documents as hex
# with the submitter's completion time, the number of signers who had
# completed by each PDF's own completion time (the first signer's PDF says 1,
# the second's 2 — what the live path records under the `multiple` signing
# preference; an equal completion time counts) and the provenance ids. Rows
# that cannot be dated (submitter gone or never completed) or decoded are
# skipped, duplicates collapse onto the unique fingerprint, and re-running
# changes nothing.
RSpec.describe BackfillVerifiedDocuments do
  let!(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, submitter_count: 2) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: author) }
  let(:first_signer) { submission.submitters.order(:id).first }
  let(:second_signer) { submission.submitters.order(:id).last }
  let(:first_bytes) { "%PDF first signer #{SecureRandom.hex}" }
  let(:second_bytes) { "%PDF second signer #{SecureRandom.hex}" }

  def urlsafe(bytes)
    Base64.urlsafe_encode64(Digest::SHA256.digest(bytes))
  end

  def hex(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  before do
    first_signer.update!(completed_at: 3.days.ago.change(usec: 0))
    second_signer.update!(completed_at: 2.days.ago.change(usec: 0))

    create(:completed_document, submitter: first_signer, sha256: urlsafe(first_bytes))
    create(:completed_document, submitter: second_signer, sha256: urlsafe(second_bytes))
  end

  it 'copies every datable fingerprint as hex with the completion time, signer count and provenance' do
    expect { run_backfill }.to change(VerifiedDocument, :count).by(2)

    first = VerifiedDocument.find_by!(sha256: hex(first_bytes))
    second = VerifiedDocument.find_by!(sha256: hex(second_bytes))

    expect(first.signed_at).to eq(first_signer.completed_at)
    expect(second.signed_at).to eq(second_signer.completed_at)
    expect([first, second].map(&:signers_count)).to eq([1, 2])
    expect([first, second].map(&:account_id).uniq).to eq([account.id])
    expect([first, second].map(&:submission_id).uniq).to eq([submission.id])
    expect([first, second].map(&:kind).uniq).to eq(['document'])
  end

  it 'counts a peer who completed at the same instant (what the signing job saw when it ran)' do
    third_bytes = "%PDF third signer #{SecureRandom.hex}"
    third_signer = create(:submitter, submission:, account:, uuid: SecureRandom.uuid,
                                      completed_at: second_signer.completed_at)
    create(:completed_document, submitter: third_signer, sha256: urlsafe(third_bytes))

    run_backfill

    counts = [first_bytes, second_bytes, third_bytes].map { |bytes| VerifiedDocument.find_by!(sha256: hex(bytes)) }
    expect(counts.map(&:signers_count)).to eq([1, 3, 3])
  end

  it 'skips rows that cannot be dated or decoded and collapses duplicate fingerprints' do
    uncompleted = create(:submitter, submission:, account:, uuid: SecureRandom.uuid, completed_at: nil)
    create(:completed_document, submitter: uncompleted, sha256: urlsafe('never completed'))

    orphan = create(:submitter, submission:, account:, uuid: SecureRandom.uuid, completed_at: 1.day.ago)
    create(:completed_document, submitter: orphan, sha256: urlsafe('submitter purged'))
    orphan.delete

    create(:completed_document, submitter: first_signer, sha256: 'not*base64*at*all')
    create(:completed_document, submitter: first_signer, sha256: Base64.urlsafe_encode64('too short'))
    create(:completed_document, submitter: second_signer, sha256: urlsafe(first_bytes))

    expect { run_backfill }.to change(VerifiedDocument, :count).by(2)

    expect(VerifiedDocument.pluck(:sha256)).to contain_exactly(hex(first_bytes), hex(second_bytes))
    expect(VerifiedDocument.find_by!(sha256: hex(first_bytes)).signed_at).to eq(first_signer.completed_at)
  end

  it 'is idempotent and leaves a record the app already wrote untouched' do
    run_backfill

    record = VerifiedDocument.find_by!(sha256: hex(second_bytes))
    record.update!(signers_count: 7)

    expect { run_backfill }.not_to change(VerifiedDocument, :count)
    expect(record.reload.signers_count).to eq(7)
  end

  it 'has a no-op down that keeps the records' do
    run_backfill

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.down } }
      .not_to change(VerifiedDocument, :count)
  end
end
