# frozen_string_literal: true

RSpec::Matchers.define_negated_matcher :not_change, :change

describe 'Admin Accounts API' do
  let(:admin_token) { 'test-provision-token' }
  let(:headers) { { 'x-admin-token': admin_token, 'content-type': 'application/json' } }

  around do |example|
    original = ENV.fetch('ADMIN_PROVISION_TOKEN', nil)
    ENV['ADMIN_PROVISION_TOKEN'] = admin_token
    RateLimit.store.clear

    example.run

    RateLimit.store.clear

    if original.nil?
      ENV.delete('ADMIN_PROVISION_TOKEN')
    else
      ENV['ADMIN_PROVISION_TOKEN'] = original
    end
  end

  describe 'POST /api/admin/accounts rate limit' do
    it 'refuses the call past the per-IP ceiling, whether or not the token is right' do
      limit = Api::Admin::AccountsController::PROVISION_RATE_LIMIT

      limit.times do
        post '/api/admin/accounts', headers: headers.merge('x-admin-token': 'wrong-token'), params: {}.to_json
        expect(response).to have_http_status(:unauthorized)
      end

      expect do
        post '/api/admin/accounts', headers: headers, params: {
          name: 'Over The Limit LLC', email: 'over-limit@example.com'
        }.to_json
      end.not_to change(Account, :count)

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body).to eq('error' => 'Too many requests')
    end
  end

  describe 'POST /api/admin/accounts' do
    it 'creates an account with an admin user, api token, esign certs and webhook' do
      expect do
        post '/api/admin/accounts', headers: headers, params: {
          name: 'Veterans First LLC',
          email: 'esign-team-abc123@example.com',
          timezone: 'America/Chicago',
          webhook: {
            url: 'https://crm.example.com/api/docuseal/webhook?team=abc123&secret=shh',
            events: ['form.completed', 'submission.completed']
          }
        }.to_json
      end.to change(Account, :count).by(1)
        .and change(User, :count).by(1)
        .and change(WebhookUrl, :count).by(1)

      expect(response).to have_http_status(:created)

      account = Account.last
      user = User.last
      webhook_url = WebhookUrl.last
      body = response.parsed_body

      expect(body['account_id']).to eq(account.id)
      expect(body['account_uuid']).to eq(account.uuid)
      expect(body['user_id']).to eq(user.id)
      expect(body['email']).to eq('esign-team-abc123@example.com')
      expect(body['api_token']).to eq(user.access_token.token)
      expect(body['webhook_url_id']).to eq(webhook_url.id)

      expect(account.name).to eq('Veterans First LLC')
      expect(account.timezone).to eq('Central Time (US & Canada)')
      expect(user.role).to eq('admin')
      expect(user.account_id).to eq(account.id)
      expect(account.encrypted_configs.find_by(key: EncryptedConfig::ESIGN_CERTS_KEY)).to be_present
      expect(webhook_url.account_id).to eq(account.id)
      expect(webhook_url.events).to eq(['form.completed', 'submission.completed'])
      expect(webhook_url.url).to eq('https://crm.example.com/api/docuseal/webhook?team=abc123&secret=shh')
    end

    it 'creates an account without a webhook when none is given' do
      expect do
        post '/api/admin/accounts', headers: headers, params: {
          name: 'Solo Rep', email: 'esign-solo@example.com'
        }.to_json
      end.to change(Account, :count).by(1).and not_change(WebhookUrl, :count)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['webhook_url_id']).to be_nil
    end

    it 'ignores unknown webhook events and falls back to defaults when none are valid' do
      post '/api/admin/accounts', headers: headers, params: {
        name: 'Firm', email: 'esign-events@example.com',
        webhook: { url: 'https://crm.example.com/hook', events: ['nope.bogus'] }
      }.to_json

      expect(response).to have_http_status(:created)
      expect(WebhookUrl.last.events)
        .to eq(%w[form.completed form.declined submission.completed submission.expired])
    end

    # W4 (session 10 staging walk). A caller that sends the flat `webhook_url`
    # instead of the nested `webhook[url]` used to get a 201 with
    # `webhook_url_id: null` and no subscription at all — nothing in the answer
    # said the webhook had been dropped, so the first missing event was the
    # first anybody knew.
    it 'accepts the flat webhook_url and webhook_events aliases' do
      expect do
        post '/api/admin/accounts', headers: headers, params: {
          name: 'Flat Firm', email: 'esign-flat@example.com',
          webhook_url: 'https://crm.example.com/api/docuseal/webhook',
          webhook_events: ['form.completed', 'submission.completed']
        }.to_json
      end.to change(WebhookUrl, :count).by(1)

      expect(response).to have_http_status(:created)

      webhook_url = WebhookUrl.last

      expect(response.parsed_body['webhook_url_id']).to eq(webhook_url.id)
      expect(response.parsed_body['webhook_hmac_secret']).to eq(webhook_url.hmac_secret)
      expect(webhook_url.url).to eq('https://crm.example.com/api/docuseal/webhook')
      expect(webhook_url.events).to eq(['form.completed', 'submission.completed'])
    end

    # The same alias with the events as one comma-separated string, which is
    # what a form post or a query string carries.
    it 'reads flat webhook_events sent as one comma-separated string' do
      post '/api/admin/accounts', headers: headers, params: {
        name: 'Flat Firm', email: 'esign-flat-csv@example.com',
        webhook_url: 'https://crm.example.com/hook',
        webhook_events: 'form.completed, submission.completed'
      }.to_json

      expect(response).to have_http_status(:created)
      expect(WebhookUrl.last.events).to eq(['form.completed', 'submission.completed'])
    end

    # Both shapes at once is a caller who is unsure, not a caller asking for
    # two webhooks: the documented nested one is the one that counts.
    it 'keeps the nested webhook when both shapes are sent' do
      expect do
        post '/api/admin/accounts', headers: headers, params: {
          name: 'Both Firm', email: 'esign-both@example.com',
          webhook: { url: 'https://crm.example.com/nested', events: ['form.completed'] },
          webhook_url: 'https://crm.example.com/flat'
        }.to_json
      end.to change(WebhookUrl, :count).by(1)

      expect(WebhookUrl.last.url).to eq('https://crm.example.com/nested')
    end

    it 'rejects requests with a wrong admin token' do
      expect do
        post '/api/admin/accounts',
             headers: { 'x-admin-token': 'wrong-token', 'content-type': 'application/json' },
             params: { name: 'Firm', email: 'esign-bad@example.com' }.to_json
      end.not_to change(Account, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects requests without an admin token' do
      post '/api/admin/accounts',
           headers: { 'content-type': 'application/json' },
           params: { name: 'Firm', email: 'esign-none@example.com' }.to_json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'is disabled when ADMIN_PROVISION_TOKEN is not configured' do
      ENV.delete('ADMIN_PROVISION_TOKEN')

      expect do
        post '/api/admin/accounts', headers: headers, params: {
          name: 'Firm', email: 'esign-disabled@example.com'
        }.to_json
      end.not_to change(Account, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it 'logs an idempotent replay without changing the response' do
      params = { name: 'Firm', email: 'esign-replay@example.com', idempotency_key: 'replay-key-1' }

      post '/api/admin/accounts', headers: headers, params: params.to_json
      expect(response).to have_http_status(:created)
      account_id = response.parsed_body['account_id']

      allow(Rails.logger).to receive(:info).and_call_original

      expect do
        post '/api/admin/accounts', headers: headers, params: params.to_json
      end.not_to change(Account, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['account_id']).to eq(account_id)
      expect(Rails.logger).to have_received(:info)
        .with("provisioning replay for account #{account_id} (idempotency key replay-key-1)")
    end

    it 'logs a warning on an idempotency key reused with different parameters' do
      post '/api/admin/accounts', headers: headers,
                                  params: { name: 'Firm', email: 'esign-conflict-a@example.com',
                                            idempotency_key: 'conflict-key-1' }.to_json
      expect(response).to have_http_status(:created)
      account_id = response.parsed_body['account_id']

      allow(Rails.logger).to receive(:warn).and_call_original

      expect do
        post '/api/admin/accounts', headers: headers,
                                    params: { name: 'Firm', email: 'esign-conflict-b@example.com',
                                              idempotency_key: 'conflict-key-1' }.to_json
      end.not_to change(Account, :count)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['error']).to eq('Idempotency key was already used with different parameters')
      expect(Rails.logger).to have_received(:warn)
        .with("provisioning idempotency conflict for account #{account_id} " \
              '(idempotency key conflict-key-1 reused with different parameters)')
    end

    it 'returns 422 with the validation message for a duplicate email' do
      create(:user, email: 'taken@example.com')

      expect do
        post '/api/admin/accounts', headers: headers, params: {
          name: 'Firm', email: 'taken@example.com'
        }.to_json
      end.not_to change(Account, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('Email has already been taken')
    end
  end
end
