# frozen_string_literal: true

# Exercise the application contract as one journey: a backend provisions its
# account, sends a generated PDF, the human signs without an EsignCenter login,
# and the backend receives a signed webhook and downloads a verifiable PDF.
RSpec.describe 'Automatically provisioned app signing', sidekiq: :inline do
  let(:api) { ActionDispatch::Integration::Session.new(Rails.application) }
  let(:callback_url) { 'https://consumer.example.com/esign/webhook' }
  let(:deliveries) { [] }

  around do |example|
    original = ENV.fetch('ADMIN_PROVISION_TOKEN', nil)
    ENV['ADMIN_PROVISION_TOKEN'] = 'local-workflow-provision-token'
    example.run
  ensure
    original.nil? ? ENV.delete('ADMIN_PROVISION_TOKEN') : ENV['ADMIN_PROVISION_TOKEN'] = original
  end

  before do
    RateLimit.store.clear
    visit '/up'
    server = URI(page.current_url)
    allow(Docuseal).to receive(:default_url_options).and_return(
      host: server.host, port: server.port, protocol: server.scheme
    )
    stub_request(:post, callback_url).with do |request|
      deliveries << request
      true
    end.to_return(status: 200)
  end

  after { RateLimit.store.clear }

  def provision_app
    api.post '/api/admin/accounts', headers: { 'X-Admin-Token' => ENV.fetch('ADMIN_PROVISION_TOKEN') },
                                    params: {
                                      name: 'Consumer Application', email: 'app-robot@example.com',
                                      idempotency_key: 'consumer-application-workspace-1',
                                      webhook: { url: callback_url, events: ['submission.completed'] }
                                    }, as: :json
    expect(api.response).to have_http_status(:created)
    api.response.parsed_body
  end

  def create_signing_session(credentials)
    api.post '/api/signing_sessions', headers: { 'X-Auth-Token' => credentials.fetch('api_token') },
                                      params: {
                                        name: 'Consumer Generated Agreement', external_id: 'consumer-record-42',
                                        embed_origin: 'https://consumer.example.com', send_email: false,
                                        documents: [{ name: 'agreement.pdf', file: Base64.strict_encode64(
                                          Rails.root.join('spec/fixtures/sample-document.pdf').binread
                                        ) }],
                                        submitters: [{ name: 'Jane Signer', email: 'signer@example.com',
                                                       role: 'Jane Signer' }],
                                        fields: [{ name: 'Full Name', type: 'text', role: 'Jane Signer', required: true,
                                                   areas: [{ x: 0.1, y: 0.3, w: 0.5, h: 0.05, page: 0, document: 0 }] }]
                                      }, as: :json
    expect(api.response).to have_http_status(:ok)
    api.response.parsed_body
  end

  def expect_signed_callback(credentials, submission_id)
    expect(deliveries.size).to eq(1)
    callback = deliveries.sole
    expect(JSON.parse(callback.body)).to include('event_type' => 'submission.completed')
    expect(JSON.parse(callback.body).dig('data', 'id')).to eq(submission_id)
    %w[X-Docuseal-Signature X-Esigncenter-Signature].each do |name|
      timestamp, digest = callback.headers.fetch(name).split('.', 2)
      expected = OpenSSL::HMAC.hexdigest('sha256', credentials.fetch('webhook_hmac_secret'),
                                         "#{timestamp}.#{callback.body}")
      expect(digest).to eq(expected)
      expect(timestamp.to_i).to be_within(120).of(Time.current.to_i)
    end
  end

  def download_signed_document(credentials, session)
    headers = { 'X-Auth-Token' => credentials.fetch('api_token') }
    api.get URI(session.fetch('status_url')).request_uri, headers: headers
    expect(api.response).to have_http_status(:ok)
    expect(api.response.parsed_body).to include('status' => 'completed', 'external_id' => 'consumer-record-42')
    api.get URI(session.fetch('documents_url')).request_uri, headers: headers
    expect(api.response).to have_http_status(:ok)
    url = api.response.parsed_body.fetch('documents').sole.fetch('url')
    api.get URI(url).request_uri, headers: headers
    expect(api.response).to have_http_status(:ok)
    expect(api.response.body).to start_with('%PDF')
    api.response.body
  end

  def save_launch_evidence(name)
    directory = Rails.root.join('tmp/launch-review')
    directory.mkpath
    page.driver.browser.screenshot(path: directory.join(name).to_s)
  end

  it 'provisions, signs in the browser, delivers a legacy-compatible callback and verifies the PDF' do
    credentials = provision_app
    account = Account.find(credentials.fetch('account_id'))
    expect(account).to be_internal
    expect(account.account_subscription).to be_nil
    expect(account.users.sole).to be_confirmed

    session = create_signing_session(credentials)
    submitter = Submitter.find(session.fetch('submitter_id'))
    visit URI(session.fetch('embed_src')).request_uri
    expect(page).to have_css('submission-form')
    expect(page).to have_no_link('Upgrade')
    field = submitter.template.fields.find { |item| item['name'] == 'Full Name' }
    find_by_id(field.fetch('uuid')).set('Jane Signer')
    save_launch_evidence('internal-app-before-consent.png')
    agree_to_esign_consent
    find('#submit_form_button').click
    expect(page).to have_content('Form has been completed!')
    save_launch_evidence('internal-app-completed.png')
    expect(submitter.reload.submission_events.where(event_type: 'esign_consent').count).to eq(1)

    expect_signed_callback(credentials, session.fetch('submission_id'))
    bytes = download_signed_document(credentials, session)
    file = Rack::Test::UploadedFile.new(StringIO.new(bytes), 'application/pdf', original_filename: 'signed.pdf')
    api.post '/verify', params: { file: }
    expect(api.response).to have_http_status(:ok)
    expect(Nokogiri::HTML(api.response.body).at_css('#verify_result')['data-state']).to eq('verified')
    expect(account.reload.account_subscription).to be_nil
  end
end
