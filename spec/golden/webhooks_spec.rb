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
    let(:account) { create(:account, :paid) }
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
    # Webhooks are paid-only: the free-account path is the "no request" example below.
    let(:account) { create(:account, :paid) }
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

    it 'makes no request for a free account (paid-only row; the URL row stays, inert)' do
      free_account = create(:account)
      free_user = create(:user, account: free_account)
      free_template = create(:template, account: free_account, author: free_user)
      free_submission = create(:submission, template: free_template, created_by_user: free_user)
      free_submitter = create(:submitter, submission: free_submission,
                                          uuid: free_template.submitters.first['uuid'], completed_at: Time.current)
      free_webhook = create(:webhook_url, account: free_account)
      stub_request(:post, free_webhook.url).to_return(status: 200)

      described_class.new.perform('submitter_id' => free_submitter.id, 'webhook_url_id' => free_webhook.id)

      expect(WebMock).not_to have_requested(:post, free_webhook.url)
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
      webhook_url = create(:webhook_url, account:)
      webhook_url.update_column(:url, 'http://example.com/webhook')

      expect do
        SendWebhookRequest.validate_webhook_uri!(webhook_url)
      end.to raise_error(SendWebhookRequest::HttpsError, 'Only HTTPS is allowed.')
    end

    it 'blocks localhost for customers' do
      webhook_url = create(:webhook_url)
      webhook_url.update_column(:url, 'https://localhost/webhook')

      expect do
        SendWebhookRequest.validate_webhook_uri!(webhook_url)
      end.to raise_error(SendWebhookRequest::LocalhostError, "Can't send to localhost.")
    end

    it 'blocks metadata hosts for customers' do
      webhook_url = create(:webhook_url)
      webhook_url.update_column(:url, 'https://169.254.169.254/webhook')

      expect do
        SendWebhookRequest.validate_webhook_uri!(webhook_url)
      end.to raise_error(SendWebhookRequest::MetadataHostError)
    end

    it 'refuses a hostless or malformed URL for every account before the scheme rules' do
      undeliverable_urls = ['https:/path', 'https://', 'not a url']

      [create(:account), create(:account, :internal)].each do |account|
        undeliverable_urls.each do |url|
          webhook_url = create(:webhook_url, account:)
          webhook_url.update_column(:url, url)

          expect do
            SendWebhookRequest.validate_webhook_uri!(webhook_url)
          end.to raise_error(SendWebhookRequest::InvalidUrlError, 'Not a valid http(s) URL.')
        end
      end
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
    # checks both the blocked HTTP request and the visible terminal event.
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

    it 'records a customer localhost URL as a terminal error without sending a request' do
      account = create(:account, :paid)
      submitter = build_submitter(account)
      webhook_url = create(:webhook_url, account:)
      webhook_url.update_column(:url, 'http://localhost/webhook')

      response = deliver(webhook_url, submitter)

      expect(response.final).to be(true)
      expect(response.status).to eq(0)
      expect(a_request(:post, 'http://localhost/webhook')).not_to have_been_made

      event = WebhookEvent.find_by!(webhook_url:)
      attempt = event.webhook_attempts.sole

      expect(event.status).to eq('error')
      expect(attempt.response_status_code).to eq(0)
      expect(attempt.response_body).to eq('Only HTTPS is allowed.')
    end

    it 'records a hostless URL as a terminal error without attempting a request' do
      account = create(:account, :paid)
      submitter = build_submitter(account)
      webhook_url = create(:webhook_url, account:)
      webhook_url.update_column(:url, 'https:/path')

      response = deliver(webhook_url, submitter)

      expect(response.final).to be(true)
      expect(response.status).to eq(0)
      expect(a_request(:any, /.*/)).not_to have_been_made

      event = WebhookEvent.find_by!(webhook_url:)

      expect(event.status).to eq('error')
      expect(event.webhook_attempts.sole.response_body).to eq('Not a valid http(s) URL.')
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

    describe 'private, resolved and production targets' do
      def production!
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      def paid_webhook(url)
        create(:webhook_url, account: create(:account, :paid)).tap do |webhook_url|
          webhook_url.update_column(:url, url)
        end
      end

      ['https://10.0.0.5/hook', 'https://192.168.1.10/hook', 'https://172.16.4.4/hook', 'https://100.64.0.1/hook',
       'https://[fd00::1]/hook', 'https://[::ffff:10.0.0.5]/hook', 'https://127.0.0.2/hook',
       'https://[fec0::1]/hook', 'https://[64:ff9b:1::a00:5]/hook'].each do |url|
        it "refuses the private literal #{url} for a customer at save time and at delivery" do
          webhook_url = build(:webhook_url, account: create(:account, :paid), url:)

          expect(webhook_url).to be_invalid
          expect(webhook_url.errors.full_messages)
            .to eq(['Webhook URL must not point at localhost or a private/metadata address'])

          saved = paid_webhook(url)
          response = deliver(saved, build_submitter(saved.account))

          expect(response.final).to be(true)
          expect(a_request(:any, /.*/)).not_to have_been_made
          expect(WebhookEvent.find_by!(webhook_url: saved).webhook_attempts.sole.response_body)
            .to eq("Can't send to a private address.")
        end
      end

      it 'refuses a customer hostname that resolves to a private address, without a request' do
        allow(SendWebhookRequest).to receive(:resolve_addresses).with('internal.example.com')
                                                                .and_return([IPAddr.new('10.1.2.3')])
        webhook_url = paid_webhook('https://internal.example.com/hook')

        response = deliver(webhook_url, build_submitter(webhook_url.account))

        expect(response.final).to be(true)
        expect(a_request(:any, /.*/)).not_to have_been_made
        expect(WebhookEvent.find_by!(webhook_url:).webhook_attempts.sole.response_body)
          .to eq("Can't send to a private address.")
      end

      it 'refuses a hostname when ANY resolved address is private or metadata' do
        allow(SendWebhookRequest).to receive(:resolve_addresses).with('mixed.example.com')
                                                                .and_return([IPAddr.new('93.184.215.14'),
                                                                             IPAddr.new('169.254.169.254')])
        webhook_url = paid_webhook('https://mixed.example.com/hook')

        deliver(webhook_url, build_submitter(webhook_url.account))

        expect(a_request(:any, /.*/)).not_to have_been_made
        expect(WebhookEvent.find_by!(webhook_url:).webhook_attempts.sole.response_body)
          .to eq("Can't send to a link-local/metadata address.")
      end

      it 'pins the connection to the address it checked (no second lookup to rebind)' do
        allow(SendWebhookRequest).to receive(:resolve_addresses).with('hooks.example.com')
                                                                .and_return([IPAddr.new('93.184.215.14')])
        webhook_url = paid_webhook('https://hooks.example.com/hook')
        stub_request(:post, 'https://hooks.example.com/hook').to_return(status: 200)
        pinned = []
        allow_any_instance_of(Net::HTTP).to receive(:ipaddr=).and_wrap_original do |original, value|
          pinned << value
          original.call(value)
        end

        deliver(webhook_url, build_submitter(webhook_url.account))

        expect(pinned).to eq(['93.184.215.14'])
        expect(a_request(:post, 'https://hooks.example.com/hook')).to have_been_made.once
        expect(WebhookEvent.find_by!(webhook_url:).status).to eq('success')
      end

      it 'does not follow a redirect toward an internal address' do
        webhook_url = paid_webhook('https://hooks.example.com/redirect')
        stub_request(:post, 'https://hooks.example.com/redirect')
          .to_return(status: 302, headers: { 'Location' => 'http://169.254.169.254/latest/meta-data' })

        deliver(webhook_url, build_submitter(webhook_url.account))

        expect(a_request(:post, 'https://hooks.example.com/redirect')).to have_been_made.once
        expect(a_request(:any, /169\.254\.169\.254/)).not_to have_been_made
      end

      it 'treats an unresolvable host as a retryable connection failure and sends nothing' do
        allow(SendWebhookRequest).to receive(:resolve_addresses).with('nowhere.example.com').and_return([])
        webhook_url = paid_webhook('https://nowhere.example.com/hook')

        response = deliver(webhook_url, build_submitter(webhook_url.account))

        expect(response).to be_nil
        expect(a_request(:any, /.*/)).not_to have_been_made
        expect(WebhookEvent.find_by!(webhook_url:).webhook_attempts.sole.response_body).to eq('ConnectionFailed')
      end

      it 'resolves real names through the hosts file (localhost is loopback, so refused)' do
        allow(OutboundAddress).to receive(:resolve).and_call_original

        expect(SendWebhookRequest.resolve_addresses('localhost')).to include(IPAddr.new('127.0.0.1'))
      end

      it 'refuses a development-mode internal hostname aliasing the metadata address, without a request' do
        account = create(:account, :internal)
        allow(SendWebhookRequest).to receive(:resolve_addresses).with('metadata-alias.test')
                                                                .and_return([IPAddr.new('169.254.169.254')])
        webhook_url = create(:webhook_url, account:, url: 'http://metadata-alias.test/hook')

        response = deliver(webhook_url, build_submitter(account))

        expect(response.final).to be(true)
        expect(a_request(:any, /.*/)).not_to have_been_made
      end

      it 'does not pin a development-mode internal delivery (localhost keeps its IPv4/IPv6 fallback)' do
        account = create(:account, :internal)
        webhook_url = create(:webhook_url, account:, url: 'http://localhost:3000/hook')

        expect(SendWebhookRequest.deliverable_address!(URI(webhook_url.url), account)).to be_nil
      end

      describe 'internal accounts in production' do
        let(:account) { create(:account, :internal) }

        before { production! }

        it 'refuses http, localhost and private addresses (the development allowance is off)' do
          { 'http://hooks.example.com/hook' => SendWebhookRequest::HttpsError,
            'https://localhost/hook' => SendWebhookRequest::LocalhostError,
            'https://10.0.0.5/hook' => SendWebhookRequest::PrivateAddressError }.each do |url, error|
            webhook_url = create(:webhook_url, account:)
            webhook_url.update_column(:url, url)

            expect { SendWebhookRequest.validate_webhook_uri!(webhook_url) }.to raise_error(error)
          end
        end

        it 'refuses the unsafe URL when it is saved (provisioning answers 422 instead of a silent dead hook)' do
          webhook_url = build(:webhook_url, account:, url: 'http://localhost:3000/hook')

          expect(webhook_url).to be_invalid
        end

        it 'records a hostname resolving to a private address as a terminal error without a request' do
          allow(SendWebhookRequest).to receive(:resolve_addresses).with('render-internal.example.com')
                                                                  .and_return([IPAddr.new('10.9.8.7')])
          webhook_url = create(:webhook_url, account:, url: 'https://render-internal.example.com/hook')

          response = deliver(webhook_url, build_submitter(account))

          expect(response.final).to be(true)
          expect(a_request(:any, /.*/)).not_to have_been_made
        end

        it 'still delivers a public HTTPS receiver with both signature headers' do
          webhook_url = create(:webhook_url, account:, url: 'https://app.example.com/api/esigncenter/webhook')
          captured = nil
          stub_request(:post, webhook_url.url).with { |request| captured = request }.to_return(status: 200)

          deliver(webhook_url, build_submitter(account))

          expect(captured.headers['X-Docuseal-Signature']).to be_present
          expect(captured.headers['X-Esigncenter-Signature']).to be_present
          expect(WebhookEvent.find_by!(webhook_url:).status).to eq('success')
        end

        it 'ignores a legacy allow_http config: HTTPS stays required in production' do
          create(:account_config, account:, key: :allow_http, value: true)
          webhook_url = create(:webhook_url, account:)
          webhook_url.update_column(:url, 'http://hooks.example.com/hook')

          expect { SendWebhookRequest.validate_webhook_uri!(webhook_url) }
            .to raise_error(SendWebhookRequest::HttpsError, 'Only HTTPS is allowed.')

          response = deliver(webhook_url, build_submitter(account))

          expect(response.final).to be(true)
          expect(a_request(:any, /.*/)).not_to have_been_made
        end

        it 'connects directly to the pinned address even when an HTTP(S)_PROXY is set' do
          allow(ENV).to receive(:[]).and_call_original
          %w[http_proxy HTTP_PROXY https_proxy HTTPS_PROXY].each do |key|
            allow(ENV).to receive(:[]).with(key).and_return('http://proxy.internal:3128')
          end
          allow(Net::HTTP).to receive(:new).and_call_original
          webhook_url = create(:webhook_url, account:, url: 'https://hooks.example.com/hook')
          stub_request(:post, webhook_url.url).to_return(status: 200)

          deliver(webhook_url, build_submitter(account))

          expect(Net::HTTP).to have_received(:new).with('hooks.example.com', 443, nil)
          expect(a_request(:post, webhook_url.url)).to have_been_made.once
        end
      end
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
