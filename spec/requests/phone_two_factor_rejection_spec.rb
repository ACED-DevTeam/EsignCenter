# frozen_string_literal: true

RSpec.describe 'Phone two-factor verification rejection', type: :request do
  let(:account) { create(:account, :internal) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }
  let(:headers) { { 'x-auth-token' => user.access_token.token } }
  let(:valid_submitter) { { role: template.submitters.first['name'], email: 'signer@example.com' } }
  let(:error_response) do
    { 'error' => 'Phone (SMS) verification is not available. Use require_email_2fa instead.' }
  end

  def expect_phone_rejection
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq(error_response)
  end

  describe 'POST /api/submissions' do
    it 'rejects a truthy top-level flag without creating a submission' do
      expect do
        post '/api/submissions', headers:, params: {
          template_id: template.id,
          require_phone_2fa: true,
          submitters: [valid_submitter]
        }.to_json
      end.not_to change(Submission, :count)

      expect_phone_rejection
    end

    it 'rejects a truthy per-submitter flag without creating a submission' do
      expect do
        post '/api/submissions', headers:, params: {
          template_id: template.id,
          submitters: [valid_submitter.merge(require_phone_2fa: '1')]
        }.to_json
      end.not_to change(Submission, :count)

      expect_phone_rejection
    end

    it 'rejects a truthy per-submission flag without creating a submission' do
      expect do
        post '/api/submissions', headers:, params: {
          template_id: template.id,
          submission: {
            require_phone_2fa: 1,
            submitters: [valid_submitter]
          }
        }.to_json
      end.not_to change(Submission, :count)

      expect_phone_rejection
    end

    it 'accepts a falsy flag without storing it' do
      expect do
        post '/api/submissions', headers:, params: {
          template_id: template.id,
          require_phone_2fa: 'false',
          submitters: [valid_submitter]
        }.to_json
      end.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(Submission.last.preferences).not_to have_key('require_phone_2fa')
      expect(Submission.last.submitters.sole.preferences).not_to have_key('require_phone_2fa')
    end
  end

  describe 'every truthy and falsy form' do
    def create_with_flag(value)
      post '/api/submissions', headers:, params: {
        template_id: template.id,
        require_phone_2fa: value,
        submitters: [valid_submitter]
      }.to_json
    end

    # The Rails boolean cast decides: anything that is not blank or an
    # explicit false form asks for phone 2FA.
    ['on', 'yes', 'TRUE', 't', 2].each do |value|
      it "rejects #{value.inspect}" do
        expect { create_with_flag(value) }.not_to change(Submission, :count)

        expect_phone_rejection
      end
    end

    ['false', 'FALSE', '0', 'off', false, 0, nil, ''].each do |value|
      it "accepts #{value.inspect} without storing it" do
        expect { create_with_flag(value) }.to change(Submission, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(Submission.last.preferences).not_to have_key('require_phone_2fa')
        expect(Submission.last.submitters.sole.preferences).not_to have_key('require_phone_2fa')
      end
    end
  end

  describe 'PUT /api/submitters/:id' do
    it 'rejects a truthy flag without changing preferences' do
      submitter = create(:submission, :with_submitters, template:, created_by_user: user).submitters.sole
      original_preferences = submitter.preferences.deep_dup

      put "/api/submitters/#{submitter.id}", headers:, params: {
        email: 'updated@example.com',
        require_phone_2fa: 'true'
      }.to_json

      expect_phone_rejection
      expect(submitter.reload.email).not_to eq('updated@example.com')
      expect(submitter.preferences).to eq(original_preferences)
    end

    it 'accepts a falsy flag without storing it' do
      submitter = create(:submission, :with_submitters, template:, created_by_user: user).submitters.sole

      put "/api/submitters/#{submitter.id}", headers:, params: {
        email: 'updated@example.com',
        require_phone_2fa: 'false'
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.email).to eq('updated@example.com')
      expect(submitter.preferences).not_to have_key('require_phone_2fa')
    end
  end

  describe 'POST /api/signing_sessions' do
    it 'rejects a truthy flag without creating a signing-session submission' do
      expect do
        post '/api/signing_sessions', headers:, params: {
          template_id: template.id,
          embed_origin: 'https://app.example.com',
          submitters: [valid_submitter.merge(require_phone_2fa: true)]
        }.to_json
      end.not_to change(Submission, :count)

      expect_phone_rejection
    end

    it 'accepts a falsy flag without storing it' do
      expect do
        post '/api/signing_sessions', headers:, params: {
          template_id: template.id,
          embed_origin: 'https://app.example.com',
          submitters: [valid_submitter.merge(require_phone_2fa: 'false')]
        }.to_json
      end.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(Submission.last.submitters.sole.preferences).not_to have_key('require_phone_2fa')
    end
  end

  it 'does not save the phone flag through template preferences' do
    sign_in(user)

    post "/templates/#{template.id}/preferences", params: {
      template: { preferences: { require_phone_2fa: '1' } }
    }

    expect(response).to have_http_status(:ok)
    expect(template.reload.preferences).not_to have_key('require_phone_2fa')
  end

  it 'opens a shared template normally when only a stale phone flag is stored' do
    template.update!(shared_link: true)
    template.update_column(:preferences, { 'require_phone_2fa' => true })

    get "/d/#{template.slug}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="submitter[email]"')
  end
end
