# frozen_string_literal: true

# A still-valid token stops working the moment its account leaves the active
# state. Session sign-in already refuses archived accounts (Devise); this
# covers every token-authenticated door instead: API keys, signing sessions,
# MCP tokens and the blob proxies that authorize a download through the
# token without ever requiring one. The refusal never says why.
RSpec.describe 'Token account state', type: :request do
  # A paid customer: the free plan has no tokens to refuse in the first place.
  let(:account) { create(:account, :paid) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:api_headers) { { 'x-auth-token': author.access_token.token } }
  let(:mcp_token) { author.mcp_tokens.create!(name: 'Golden') }
  let(:mcp_headers) { { 'Authorization' => "Bearer #{mcp_token.token}", 'Content-Type' => 'application/json' } }
  let(:refusal) { { 'error' => 'Account is not active' } }

  def archive!(account)
    account.update!(archived_at: Time.current)
  end

  def create_submission
    post '/api/submissions', headers: api_headers, params: {
      template_id: template.id,
      send_email: false,
      submitters: [{ role: template.submitters.first['name'], email: 'signer@example.com' }]
    }.to_json
  end

  def create_signing_session
    post '/api/signing_sessions', headers: api_headers, params: {
      template_id: template.id,
      embed_origin: 'https://app.example.com',
      submitters: [{ role: template.submitters.first['name'], email: 'signer@example.com' }]
    }.to_json
  end

  def mcp_tools_list
    post '/mcp', headers: mcp_headers, params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json
  end

  describe AccountStates do
    it 'allows tokens for an active account and refuses them once archived' do
      expect(described_class.tokens_allowed?(account)).to be(true)

      archive!(account)

      expect(described_class.tokens_allowed?(account)).to be(false)
      expect(described_class.tokens_allowed?(nil)).to be(false)
    end

    it 'names archived_at as the only refusal state until Session 7 adds suspension' do
      expect(described_class::TOKEN_REFUSAL_STATES).to eq(%i[archived_at])
    end
  end

  describe 'GET /api/templates' do
    it 'serves the token before the account is archived and refuses the same token after' do
      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:ok)

      archive!(account)

      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq(refusal)
    end

    it 'keeps refusing a missing token as not authenticated' do
      get '/api/templates', headers: { 'x-auth-token': 'not-a-token' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'Not authenticated')
    end
  end

  describe 'POST /api/submissions' do
    it 'creates before the archive and refuses without creating after it' do
      expect { create_submission }.to change(Submission, :count).by(1)
      expect(response).to have_http_status(:ok)

      archive!(account)

      expect { create_submission }.not_to change(Submission, :count)
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq(refusal)
    end
  end

  describe 'POST /api/signing_sessions' do
    it 'creates before the archive and refuses without creating after it' do
      expect { create_signing_session }.to change(Submission, :count).by(1)
      expect(response).to have_http_status(:ok)

      archive!(account)

      expect { create_signing_session }.not_to change(Submission, :count)
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq(refusal)
    end
  end

  describe 'POST /mcp' do
    before do
      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)
    end

    it 'answers the MCP token before the archive and refuses it after' do
      mcp_tools_list

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('result', 'tools')).to be_present

      archive!(account)

      mcp_tools_list

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq(refusal)
    end
  end

  describe 'GET the blob proxy' do
    # An expired download link is served only to a token (or session) that
    # can read the record — the proxy skips authenticate_user! and decides
    # through current_user, so the state guard has to hold there too.
    let(:blob) { template.documents.first.blob }
    let(:expired_path) { ActiveStorage::Blob.proxy_path(blob, expires_at: 1.hour.ago) }

    it 'serves an expired link to the token before the archive and refuses it after' do
      get expired_path, headers: api_headers

      expect(response).to have_http_status(:ok)

      archive!(account)

      get expired_path, headers: api_headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq(refusal)
    end

    it 'still serves a public logo blob to an anonymous visitor' do
      account.logo.attach(io: Rails.root.join('spec/fixtures/sample-image.png').open,
                          filename: 'logo.png', content_type: 'image/png')
      archive!(account)

      get ActiveStorage::Blob.proxy_path(account.logo.blob)

      expect(response).to have_http_status(:ok)
    end

    # Every API controller that skips authenticate_user! keeps the state guard
    # on its callback chain. (The legacy blob proxy controller was removed in
    # Session 3 together with its never-mounted route.)
    it 'keeps the state guard on every API controller that skips authenticate_user!' do
      controllers = [
        Api::ActiveStorageBlobsProxyController,
        Api::SubmitterFormViewsController, Api::SubmitterEmailClicksController, Api::Admin::AccountsController
      ]

      controllers.each do |controller|
        filters = controller._process_action_callbacks.select { |callback| callback.kind == :before }.map(&:filter)

        expect(filters).to include(:refuse_inactive_token_account!), controller.name
        expect(filters).not_to include(:authenticate_user!), controller.name
      end
    end
  end

  describe 'GET/PUT /embed/template_builder/:token' do
    # The builder token is minted by an API-key call and opens the embedded
    # builder without a login, so it is a token door like the others: the
    # refusal is the same 404 an invalid token gets.
    def builder_payload(name)
      { template: { name:, schema: template.schema, submitters: template.submitters,
                    fields: template.fields, variables_schema: {} } }.to_json
    end

    def update_builder_template(token, name)
      put "/embed/template_builder/#{token}/templates/#{template.id}",
          params: builder_payload(name), headers: { 'CONTENT_TYPE' => 'application/json' }
    end

    it 'opens and saves before the archive and is a 404 without saving after it' do
      post '/api/template_builder_sessions', headers: api_headers, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      expect(response).to have_http_status(:ok)

      token = URI.parse(response.parsed_body['builder_src']).path.split('/').last

      get "/embed/template_builder/#{token}"

      expect(response).to have_http_status(:ok)

      update_builder_template(token, 'Before archive')

      expect(response).to have_http_status(:ok)
      expect(template.reload.name).to eq('Before archive')

      archive!(account)

      expect { get "/embed/template_builder/#{token}" }.to raise_error(ActionController::RoutingError)
      expect { update_builder_template(token, 'After archive') }.to raise_error(ActionController::RoutingError)
      expect do
        post "/embed/template_builder/#{token}/templates/#{template.id}/documents", params: { files: [] }
      end.to raise_error(ActionController::RoutingError)

      expect(template.reload.name).to eq('Before archive')
    end
  end

  describe 'testing-child tokens' do
    let(:account) { create(:account, :internal) }

    # The test-mode API key belongs to the testing child, which is the same
    # tenant as its parent: archiving the parent alone must refuse it.
    it 'refuses the test-mode API key once the parent account is archived' do
      sign_in(author)
      post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

      expect(response).to have_http_status(:redirect)

      sign_out(:user)

      testing_child = account.testing_accounts.reload.sole
      child_headers = { 'x-auth-token': testing_child.users.sole.access_token.token }

      get '/api/templates', headers: child_headers

      expect(response).to have_http_status(:ok)

      archive!(account)

      expect(testing_child.reload.archived_at).to be_nil

      get '/api/templates', headers: child_headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq(refusal)
    end
  end

  describe 'internal accounts' do
    let(:account) { create(:account, :internal) }

    # The guard is state-based, never kind-based: an internal account's token
    # works while the account is active and refuses once it is archived.
    it 'is refused only by state, not by account kind' do
      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:ok)

      archive!(account)

      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq(refusal)
    end
  end

  describe 'session users' do
    it 'still signs an active-account user in through the browser session' do
      sign_in(author)

      get '/templates'

      expect(response).to have_http_status(:ok)
    end
  end
end
