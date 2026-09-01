# frozen_string_literal: true

RSpec.describe MailConfigs, type: :lib do
  let(:smtp_env_keys) do
    %w[
      EMAIL_DELIVERY_MODE
      POSTMARK_API_TOKEN
      SMTP_ADDRESS
      SMTP_AUTHENTICATION
      SMTP_DOMAIN
      SMTP_ENABLE_SSL
      SMTP_ENABLE_STARTTLS
      SMTP_ENABLE_TLS
      SMTP_FROM
      SMTP_OPEN_TIMEOUT
      SMTP_PASSWORD
      SMTP_PORT
      SMTP_READ_TIMEOUT
      SMTP_SSL_VERIFY
      SMTP_USERNAME
    ]
  end

  around do |example|
    original_values = smtp_env_keys.index_with { |key| ENV.fetch(key, nil) }
    smtp_env_keys.each { |key| ENV.delete(key) }

    example.run
  ensure
    original_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def create_smtp_config(account, overrides = {})
    create(
      :encrypted_config,
      account:,
      key: EncryptedConfig::EMAIL_SMTP_KEY,
      value: {
        'host' => 'pinned.smtp.example',
        'port' => '587',
        'username' => 'pinned-user',
        'password' => 'pinned-password',
        'from_email' => 'tenant@example.com',
        'authentication' => 'plain'
      }.merge(overrides)
    )
  end

  describe '.resolve' do
    it 'prefers the account SMTP config over the platform environment' do
      account = create(:account, name: 'Tenant "Quoted" Name')
      create_smtp_config(account)
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'

      result = described_class.resolve(account)

      expect(result.source).to eq(:account)
      expect(result.smtp).to include(
        address: 'pinned.smtp.example',
        user_name: 'pinned-user',
        open_timeout: MailConfigs::OPEN_TIMEOUT,
        read_timeout: MailConfigs::READ_TIMEOUT
      )
      expect(result.from).to eq('"Tenant Quoted Name" <tenant@example.com>')
    end

    it 'builds the platform default and uses the Postmark token for both credentials' do
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
      ENV['SMTP_FROM'] = 'platform@example.com'
      ENV['POSTMARK_API_TOKEN'] = 'server-token'

      result = described_class.resolve(create(:account))

      expect(result.source).to eq(:env)
      expect(result.smtp).to include(
        address: 'platform.smtp.example',
        port: '587',
        user_name: 'server-token',
        password: 'server-token',
        authentication: 'plain',
        open_timeout: MailConfigs::OPEN_TIMEOUT,
        read_timeout: MailConfigs::READ_TIMEOUT
      )
      expect(result.from).to eq('platform@example.com')
    end

    it 'returns none when neither account nor platform SMTP is configured' do
      result = described_class.resolve(create(:account))

      expect(result).to have_attributes(source: :none, smtp: {}, from: nil)
    end
  end

  describe '.delivery_mode' do
    it 'reads a valid explicit mode on every call' do
      ENV['EMAIL_DELIVERY_MODE'] = 'smtp'
      expect(described_class.delivery_mode).to eq('smtp')

      ENV['EMAIL_DELIVERY_MODE'] = 'test'
      expect(described_class.delivery_mode).to eq('test')
    end

    it 'defaults to smtp in production and test elsewhere' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))
      expect(described_class.delivery_mode).to eq('smtp')

      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))
      expect(described_class.delivery_mode).to eq('test')
    end
  end

  describe EmailDeliveryConfig do
    before do
      ENV['EMAIL_DELIVERY_MODE'] = 'smtp'
    end

    it 'raises at boot in production when SMTP_ADDRESS is missing' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check! }
        .to raise_error(RuntimeError, /EMAIL_DELIVERY_MODE=smtp but SMTP_ADDRESS is not set/)
    end

    it 'warns without raising in development when SMTP_ADDRESS is missing' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))
      allow(Rails.logger).to receive(:warn)

      expect { described_class.check! }.not_to raise_error
      expect(Rails.logger).to have_received(:warn)
        .with(/EMAIL_DELIVERY_MODE=smtp but SMTP_ADDRESS is not set/)
    end
  end
end
