# frozen_string_literal: true

# A still-valid token stops working the moment its account leaves the active
# state. Session sign-in already refuses archived accounts (Devise); this
# covers every token-authenticated door instead: API keys, signing sessions
# and MCP tokens. The refusal never says why.
RSpec.describe 'Token account state', type: :request do
  let(:account) { create(:account) }
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
