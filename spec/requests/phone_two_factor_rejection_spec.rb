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

  describe 'free-form data bags' do
    # metadata, values and fields are the customer's own data and cannot
    # switch 2FA on, so a key named require_phone_2fa inside them is not a
    # request for it — the flag is inspected only where it would take effect.
    it 'accepts the key inside submitter metadata and values without storing a preference' do
      expect do
        post '/api/submissions', headers:, params: {
          template_id: template.id,
          submitters: [valid_submitter.merge(metadata: { require_phone_2fa: true },
                                             values: { require_phone_2fa: 'yes' })]
        }.to_json
      end.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)

      submitter = Submission.last.submitters.sole

      expect(submitter.preferences).not_to have_key('require_phone_2fa')
      expect(submitter.metadata).to eq({ 'require_phone_2fa' => true })
      expect(submitter.values).not_to have_key('require_phone_2fa')
    end

    it 'accepts the key as a field name and inside a message body' do
      field_name = template.fields.find { |f| f['type'] == 'text' }['name']

      expect do
        post '/api/submissions', headers:, params: {
          template_id: template.id,
          message: { subject: 'Sign please', body: 'Set require_phone_2fa: true on your side if you want.' },
          submitters: [valid_submitter.merge(fields: [{ name: field_name, default_value: 'require_phone_2fa' }])]
        }.to_json
      end.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(Submission.last.submitters.sole.preferences).not_to have_key('require_phone_2fa')
    end

    it 'accepts the key inside submitter metadata on PUT /api/submitters/:id' do
      submitter = create(:submission, :with_submitters, template:, created_by_user: user).submitters.sole

      put "/api/submitters/#{submitter.id}", headers:, params: {
        email: 'updated@example.com',
        metadata: { require_phone_2fa: true }
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.email).to eq('updated@example.com')
      expect(submitter.preferences).not_to have_key('require_phone_2fa')
    end

    it 'accepts the key inside signing-session submitter values' do
      expect do
        post '/api/signing_sessions', headers:, params: {
          template_id: template.id,
          embed_origin: 'https://app.example.com',
          submitters: [valid_submitter.merge(values: { require_phone_2fa: true })]
        }.to_json
      end.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'structural locations' do
    it 'rejects the flag on a submissions array entry and on its submitter' do
      [
        { submissions: [{ require_phone_2fa: true, submitters: [valid_submitter] }] },
        { submissions: [{ submitters: [valid_submitter.merge(require_phone_2fa: 'on')] }] },
        { submission: { submitters: [valid_submitter.merge(require_phone_2fa: 1)] } }
      ].each do |body|
        expect do
          post '/api/submissions', headers:, params: { template_id: template.id }.merge(body).to_json
        end.not_to change(Submission, :count)

        expect_phone_rejection
      end
    end

    it 'rejects the flag inside a preferences hash on a submitter or at the top level' do
      [
        { preferences: { require_phone_2fa: true }, submitters: [valid_submitter] },
        { submitters: [valid_submitter.merge(preferences: { require_phone_2fa: 'yes' })] }
      ].each do |body|
        expect do
          post '/api/submissions', headers:, params: { template_id: template.id }.merge(body).to_json
        end.not_to change(Submission, :count)

        expect_phone_rejection
      end
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
