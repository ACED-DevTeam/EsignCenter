# frozen_string_literal: true

describe 'Tools API' do
  let(:account) { create(:account, :paid) }
  let(:author) { create(:user, account:) }

  before do
    platform_certificate!
  end

  describe 'POST /api/tools/verify' do
    it 'finds a completed submission combined PDF in the permanent verification records', sidekiq: :inline do
      template = create(:template, account:, author:, only_field_types: %w[text], submitter_count: 2)
      submission = create(:submission, :with_submitters, :with_events, template:, created_by_user: author)
      submission.submitters.each { |submitter| complete!(submitter) }
      combined = Submissions::GenerateCombinedAttachment.call(submission.submitters.order(:completed_at).last)
      bytes = combined.download

      expect(VerifiedDocument.exists?(sha256: Digest::SHA256.hexdigest(bytes))).to be(true)

      post '/api/tools/verify', headers: { 'x-auth-token': author.access_token.token }, params: {
        file: Base64.encode64(bytes)
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['checksum_status']).to eq('verified')
    end
  end
end
