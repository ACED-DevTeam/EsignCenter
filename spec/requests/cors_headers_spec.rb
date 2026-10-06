# frozen_string_literal: true

# Cross-origin reads get a wildcard origin at most. A wildcard may never be
# paired with Allow-Credentials (browsers reject the pair, and nothing here is
# authorised by cookies across origins), and the API never reflects the caller's
# Origin, so no page on another site can make credentialed API reads.
describe 'CORS headers' do
  let(:origin) { 'https://evil.example' }

  def expect_no_credentials_grant
    expect(response.headers).not_to have_key('Access-Control-Allow-Credentials')
    expect(response.headers['Access-Control-Allow-Origin']).not_to eq(origin)
  end

  it 'sends a wildcard origin without Allow-Credentials on the file proxy' do
    get '/file/not-a-signed-id/document.pdf', headers: { 'Origin' => origin }

    expect(response).to have_http_status(:not_found)
    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
    expect_no_credentials_grant
  end

  it 'grants no credentials on a token-authenticated API request' do
    user = create(:user, account: create(:account, :internal))

    get '/api/templates', headers: { 'x-auth-token': user.access_token.token, 'Origin' => origin }

    expect(response).to have_http_status(:ok)
    expect_no_credentials_grant
  end

  # There is no OPTIONS route: a preflight is answered by the exceptions app
  # (ErrorsController) with its JSON 404 and wildcard CORS headers, exactly as in
  # production, where exceptions are rendered rather than raised.
  describe 'API preflight' do
    around do |example|
      env_config = Rails.application.env_config
      overrides = { 'action_dispatch.show_exceptions' => :all, 'action_dispatch.show_detailed_exceptions' => false }
      saved = overrides.keys.index_with { |key| [env_config.key?(key), env_config[key]] }
      env_config.merge!(overrides)

      example.run
    ensure
      saved.each { |key, (present, value)| present ? env_config[key] = value : env_config.delete(key) }
    end

    it 'answers an OPTIONS preflight with a wildcard origin and no Allow-Credentials' do
      process :options, '/api/templates',
              headers: { 'Origin' => origin, 'Access-Control-Request-Method' => 'GET', 'Accept' => 'application/json' }

      expect(response).to have_http_status(:not_found)
      expect(response.media_type).to eq('application/json')
      expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
      expect_no_credentials_grant
    end
  end
end
