# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Webhook hardening' do
  # The wire contract, restated independently of the implementation: the
  # header value is "<unix timestamp>.<hex HMAC-SHA256 of '<timestamp>.<body>'
  # keyed with the webhook secret>". Computed here with bare OpenSSL on
  # purpose — calling Signatures.sign/verify would make the assertion a
  # tautology that survives a digest swap or a framing change.
  def expect_wire_signature!(header_value, secret:, body:)
    expect(header_value).to match(/\A\d+\.[0-9a-f]{64}\z/)

    timestamp, digest = header_value.split('.', 2)

    expect(Integer(timestamp)).to be_within(120).of(Time.current.to_i)
    expect(digest).to eq(OpenSSL::HMAC.hexdigest('sha256', secret, "#{timestamp}.#{body}"))
  end

  describe 'signed webhook delivery' do
    let(:account) { create(:account) }
    let(:webhook_url) { create(:webhook_url, account:, events: ['submission.created']) }

    it 'sends valid legacy and EsignCenter signatures for the same body' do
      captured_request = nil
      stub_request(:post, webhook_url.url).with do |request|
        captured_request = request
      end.to_return(status: 200)

      SendWebhookRequest.call(webhook_url, event_uuid: nil, event_type: 'submission.created', record: nil,
                                           data: { id: 123 })

      expect(captured_request).to be_present

      # Literal header names: renaming or dropping either one is a breaking
      # change for every receiver already deployed against them.
      %w[X-Docuseal-Signature X-Esigncenter-Signature].each do |header|
        expect_wire_signature!(captured_request.headers[header],
                               secret: webhook_url.hmac_secret,
                               body: captured_request.body)
      end
    end

    it 'rejects a signature older than the replay window and accepts a fresh one' do
      body = '{"id":123}'
      secret = webhook_url.hmac_secret
      tolerance = WebhookUrls::Signatures::TOLERANCE

      stale_timestamp = Time.current.to_i - tolerance - 60
      stale_header =
        "#{stale_timestamp}.#{OpenSSL::HMAC.hexdigest('sha256', secret, "#{stale_timestamp}.#{body}")}"

      expect { WebhookUrls::Signatures.verify(secret, body:, header: stale_header) }
        .to raise_error(WebhookUrls::Signatures::TimestampError, 'Too old')

      future_timestamp = Time.current.to_i + tolerance + 60
      future_header =
        "#{future_timestamp}.#{OpenSSL::HMAC.hexdigest('sha256', secret, "#{future_timestamp}.#{body}")}"

      expect { WebhookUrls::Signatures.verify(secret, body:, header: future_header) }
        .to raise_error(WebhookUrls::Signatures::TimestampError, 'In future')

      fresh_timestamp = Time.current.to_i
      fresh_header =
        "#{fresh_timestamp}.#{OpenSSL::HMAC.hexdigest('sha256', secret, "#{fresh_timestamp}.#{body}")}"

      expect(WebhookUrls::Signatures.verify(secret, body:, header: fresh_header)).to be(true)
    end

    it 'rejects a fresh timestamp carrying a digest for a different body' do
      secret = webhook_url.hmac_secret
      timestamp = Time.current.to_i
      header = "#{timestamp}.#{OpenSSL::HMAC.hexdigest('sha256', secret, "#{timestamp}.{\"id\":1}")}"

      expect { WebhookUrls::Signatures.verify(secret, body: '{"id":2}', header:) }
        .to raise_error(WebhookUrls::Signatures::InvalidSignatureError)
    end

    # The custom-secret behaviour below is the product's legacy contract: a
    # user-set static header wins over the generated signature. Unchanged.
    SendWebhookRequest::SIGNATURE_HEADERS.each do |custom_header|
      it "preserves a custom #{custom_header} header" do
        webhook_url.update!(secret: { custom_header => 'custom-signature' })
        captured_request = nil
        stub_request(:post, webhook_url.url).with do |request|
          captured_request = request
        end.to_return(status: 200)

        SendWebhookRequest.call(webhook_url, event_uuid: nil, event_type: 'submission.created', record: nil,
                                             data: { id: 123 })

        generated_header = (SendWebhookRequest::SIGNATURE_HEADERS - [custom_header]).sole

        expect(captured_request.headers[custom_header]).to eq('custom-signature')
        expect(WebhookUrls::Signatures.verify(webhook_url.hmac_secret,
                                              body: captured_request.body,
                                              header: captured_request.headers[generated_header])).to be(true)
      end
    end
  end

  describe SendTestWebhookRequestJob do
    let(:account) { create(:account) }
    let(:user) { create(:user, account:) }
    let(:template) { create(:template, account:, author: user) }
    let(:submission) { create(:submission, template:, created_by_user: user) }
    let(:submitter) do
      create(:submitter, submission:, uuid: template.submitters.first['uuid'], completed_at: Time.current)
    end
    let(:webhook_url) { create(:webhook_url, account:) }

    it 'sends valid legacy and EsignCenter signatures for the exact request body' do
      captured_request = nil
      stub_request(:post, webhook_url.url).with do |request|
        captured_request = request
      end.to_return(status: 200)

      described_class.new.perform('submitter_id' => submitter.id, 'webhook_url_id' => webhook_url.id)

      %w[X-Docuseal-Signature X-Esigncenter-Signature].each do |header|
        expect_wire_signature!(captured_request.headers[header],
                               secret: webhook_url.hmac_secret,
                               body: captured_request.body)
      end
    end

    it 'blocks metadata hosts for internal accounts' do
      internal_account = create(:account, :internal)
      internal_user = create(:user, account: internal_account)
      internal_template = create(:template, account: internal_account, author: internal_user)
      internal_submission = create(:submission, template: internal_template, created_by_user: internal_user)
      internal_submitter = create(:submitter, submission: internal_submission,
                                              uuid: internal_template.submitters.first['uuid'])
      metadata_webhook = create(:webhook_url, account: internal_account, url: 'http://169.254.169.254/webhook')

      expect do
        described_class.new.perform('submitter_id' => internal_submitter.id,
                                    'webhook_url_id' => metadata_webhook.id)
      end.to raise_error(SendWebhookRequest::MetadataHostError)
    end
  end

  describe '.validate_webhook_uri!' do
    it 'requires HTTPS for customers even when allow_http is configured' do
      account = create(:account)
      create(:account_config, account:, key: :allow_http, value: true)
      webhook_url = create(:webhook_url, account:, url: 'http://example.com/webhook')

      expect do
        SendWebhookRequest.validate_webhook_uri!(webhook_url)
      end.to raise_error(SendWebhookRequest::HttpsError, 'Only HTTPS is allowed.')
    end

    it 'blocks localhost for customers' do
      webhook_url = create(:webhook_url, url: 'https://localhost/webhook')

      expect do
        SendWebhookRequest.validate_webhook_uri!(webhook_url)
      end.to raise_error(SendWebhookRequest::LocalhostError, "Can't send to localhost.")
    end

    it 'blocks metadata hosts for customers' do
      webhook_url = create(:webhook_url, url: 'https://169.254.169.254/webhook')

      expect do
        SendWebhookRequest.validate_webhook_uri!(webhook_url)
      end.to raise_error(SendWebhookRequest::MetadataHostError)
    end

    it 'allows HTTP localhost URLs for internal accounts when multitenancy is disabled' do
      webhook_url = create(:webhook_url, account: create(:account, :internal),
                                         url: 'http://localhost:3000/webhook')

      uri = SendWebhookRequest.validate_webhook_uri!(webhook_url)

      expect(uri.to_s).to eq(webhook_url.url)
    end
  end

  describe 'SSRF enforcement on the delivery path' do
    # The refusals above call validate_webhook_uri! directly. The guard has to
    # live inside SendWebhookRequest.call itself: if the call site stopped
    # validating, every example above would stay green while a customer's
    # webhook posted to localhost. So this drives the real delivery path and
    # checks the two things that only happen after validation — the HTTP
    # request and the WebhookEvent row.
    def deliver(webhook_url, submitter)
      SendWebhookRequest.call(webhook_url, event_uuid: SecureRandom.uuid, event_type: 'submission.created',
                                           record: submitter, data: { id: submitter.id })
    end

    def build_submitter(account)
      user = create(:user, account:)
      template = create(:template, account:, author: user, attachment_count: 0)
      submission = create(:submission, template:, created_by_user: user)

      create(:submitter, submission:, uuid: template.submitters.first['uuid'])
    end

    it 'refuses a customer localhost URL before any request or event exists' do
      account = create(:account)
      submitter = build_submitter(account)
      webhook_url = create(:webhook_url, account:, url: 'http://localhost/webhook')

      expect do
        deliver(webhook_url, submitter)
      end.to raise_error(SendWebhookRequest::HttpsError, 'Only HTTPS is allowed.')

      expect(a_request(:post, 'http://localhost/webhook')).not_to have_been_made
      expect(WebhookEvent.where(webhook_url:)).to be_empty
    end

    it 'delivers the same localhost URL for an internal account' do
      account = create(:account, :internal)
      submitter = build_submitter(account)
      webhook_url = create(:webhook_url, account:, url: 'http://localhost/webhook')
      stub_request(:post, 'http://localhost/webhook').to_return(status: 200)

      deliver(webhook_url, submitter)

      expect(a_request(:post, 'http://localhost/webhook')).to have_been_made.once
      expect(WebhookEvent.find_by!(webhook_url:).status).to eq('success')
    end
  end

  describe 'launch kill switches' do
    [
      ['registration', 'REGISTRATION_ENABLED', :registration_enabled?, 'TRUE'],
      ['billing', 'BILLING_ENABLED', :billing_enabled?, '1']
    ].each do |label, env_key, predicate, non_true_value|
      it "keeps #{label} disabled unless its environment value is exactly true" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with(env_key).and_return(nil)
        expect(Docuseal.public_send(predicate)).to be(false)

        allow(ENV).to receive(:[]).with(env_key).and_return(non_true_value)
        expect(Docuseal.public_send(predicate)).to be(false)

        allow(ENV).to receive(:[]).with(env_key).and_return('true')
        expect(Docuseal.public_send(predicate)).to be(true)
      end
    end

    it 'returns 404 from both controller guards when their switches are off' do
      allow(Docuseal).to receive_messages(registration_enabled?: false, billing_enabled?: false)

      expect(status_from_controller_guard(:require_registration_enabled!)).to eq(404)
      expect(status_from_controller_guard(:require_billing_enabled!)).to eq(404)
    end
  end

  describe WebhookUrls do
    it 'returns an accounts own event-matching URLs when it has no non-testing links' do
      account = create(:account, :paid)
      matching_webhook = create(:webhook_url, account:, events: ['submission.created'])
      create(:webhook_url, account:, events: ['submission.completed'])

      expect(described_class.for_account_id(account.id, 'submission.created')).to contain_exactly(matching_webhook)
    end

    it 'never fans a customer account out to a linked parent endpoint' do
      parent = create(:account, :internal)
      customer = create(:account, :paid)
      AccountLinkedAccount.create!(account: parent, linked_account: customer, account_type: 'linked')
      create(:webhook_url, account: parent, events: ['submission.created'])

      expect(described_class.for_account_id(customer.id, 'submission.created')).to be_empty
    end

    it 'keeps the linked-parent fan-out for internal accounts with no own URLs' do
      parent = create(:account, :internal)
      child = create(:account, :internal)
      AccountLinkedAccount.create!(account: parent, linked_account: child, account_type: 'linked')
      parent_webhook = create(:webhook_url, account: parent, events: ['submission.created'])

      expect(described_class.for_account_id(child.id, 'submission.created')).to contain_exactly(parent_webhook)
    end
  end

  def status_from_controller_guard(guard)
    controller_class = Class.new(ActionController::Base) do
      include LaunchGates

      before_action guard

      def index
        head :ok
      end
    end

    controller_class.action(:index).call(Rack::MockRequest.env_for('/')).first
  end
end
# rubocop:enable RSpec/DescribeClass
