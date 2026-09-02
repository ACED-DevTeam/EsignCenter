# frozen_string_literal: true

RSpec.describe WebhookUrl do
  it 'rejects an HTTP URL for a customer account with a message that names the field' do
    webhook_url = build(:webhook_url, account: create(:account), url: 'http://example.com/webhook')

    expect(webhook_url).to be_invalid
    expect(webhook_url.errors[:url]).to include('must use https')
    expect(webhook_url.errors.full_messages).to eq(['Webhook URL must use https'])
  end

  it 'rejects a localhost URL for a customer account' do
    webhook_url = build(:webhook_url, account: create(:account), url: 'https://localhost/webhook')

    expect(webhook_url).to be_invalid
    expect(webhook_url.errors.full_messages)
      .to eq(['Webhook URL must not point at localhost or a private/metadata address'])
  end

  # "https:/path" parses as HTTPS with no host, so it used to pass the https
  # rule and save a URL nothing could be posted to.
  ['https:/path', 'https://', 'not a url', 'ftp://example.com/hook'].each do |url|
    it "rejects #{url.inspect} as not a full URL and does not save it" do
      webhook_url = build(:webhook_url, account: create(:account), url:)

      expect(webhook_url).to be_invalid
      expect(webhook_url.errors.full_messages)
        .to eq(['Webhook URL must be a full URL with a host, such as https://example.com/webhook'])
      expect(webhook_url.save).to be(false)
      expect(described_class.count).to eq(0)
    end
  end

  it 'accepts a public HTTPS URL for a customer account' do
    webhook_url = build(:webhook_url, account: create(:account), url: 'https://hooks.example.com/webhook')

    expect(webhook_url).to be_valid
  end

  it 'accepts an HTTP URL for an internal account' do
    webhook_url = build(:webhook_url, account: create(:account, :internal), url: 'http://localhost/webhook')

    expect(webhook_url).to be_valid
  end

  describe 'a legacy customer row with an http URL' do
    # Written the way such a row sits in the table: before the URL check
    # existed, so without going through today's validation.
    def legacy_row(account, url)
      build(:webhook_url, account:, url:).tap do |webhook_url|
        webhook_url.set_sha1
        webhook_url.set_hmac_secret
        webhook_url.save!(validate: false)
      end
    end

    let(:legacy) { legacy_row(create(:account), 'http://example.com/legacy') }

    it 'keeps saving its events and secret header without re-validating the URL' do
      legacy.events.push('form.completed')

      expect(legacy.save).to be(true)
      expect(legacy.update(secret: { 'X-Key' => 'value' })).to be(true)
      expect(legacy.reload.events).to include('form.completed')
    end

    it 'validates the URL again as soon as it changes' do
      legacy.url = 'http://example.com/other'

      expect(legacy).to be_invalid
      expect(legacy.errors.full_messages).to eq(['Webhook URL must use https'])

      legacy.url = 'https://example.com/other'

      expect(legacy).to be_valid
    end

    it 'leaves an internal http row unaffected' do
      internal = legacy_row(create(:account, :internal), 'http://localhost/webhook')
      internal.events.push('form.completed')

      expect(internal.save).to be(true)
      expect(internal.update(url: 'http://localhost/other')).to be(true)
    end
  end
end
