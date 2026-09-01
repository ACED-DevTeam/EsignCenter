# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Webhook hardening' do
  before do
    allow(Docuseal).to receive(:multitenant?).and_return(false)
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

      SendWebhookRequest::SIGNATURE_HEADERS.each do |header|
        signature = captured_request.headers[header]

        expect(signature).to be_present
        expect(WebhookUrls::Signatures.verify(webhook_url.hmac_secret,
                                              body: captured_request.body,
                                              header: signature)).to be(true)
      end
    end

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

      SendWebhookRequest::SIGNATURE_HEADERS.each do |header|
        expect(WebhookUrls::Signatures.verify(webhook_url.hmac_secret,
                                              body: captured_request.body,
                                              header: captured_request.headers[header])).to be(true)
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

  describe 'launch kill switches' do
    it 'keeps registration disabled unless its environment value is exactly true' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('REGISTRATION_ENABLED').and_return(nil)
      expect(Docuseal.registration_enabled?).to be(false)

      allow(ENV).to receive(:[]).with('REGISTRATION_ENABLED').and_return('TRUE')
      expect(Docuseal.registration_enabled?).to be(false)

      allow(ENV).to receive(:[]).with('REGISTRATION_ENABLED').and_return('true')
      expect(Docuseal.registration_enabled?).to be(true)
    end

    it 'keeps billing disabled unless its environment value is exactly true' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('BILLING_ENABLED').and_return(nil)
      expect(Docuseal.billing_enabled?).to be(false)

      allow(ENV).to receive(:[]).with('BILLING_ENABLED').and_return('1')
      expect(Docuseal.billing_enabled?).to be(false)

      allow(ENV).to receive(:[]).with('BILLING_ENABLED').and_return('true')
      expect(Docuseal.billing_enabled?).to be(true)
    end

    it 'returns 404 from both controller guards when their switches are off' do
      allow(Docuseal).to receive_messages(registration_enabled?: false, billing_enabled?: false)

      expect(status_from_controller_guard(:require_registration_enabled!)).to eq(404)
      expect(status_from_controller_guard(:require_billing_enabled!)).to eq(404)
    end
  end

  describe WebhookUrls do
    it 'returns an accounts own event-matching URLs when it has no non-testing links' do
      account = create(:account)
      matching_webhook = create(:webhook_url, account:, events: ['submission.created'])
      create(:webhook_url, account:, events: ['submission.completed'])

      expect(described_class.for_account_id(account.id, 'submission.created')).to contain_exactly(matching_webhook)
    end

    it 'never fans a customer account out to a linked parent endpoint' do
      parent = create(:account, :internal)
      customer = create(:account)
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
