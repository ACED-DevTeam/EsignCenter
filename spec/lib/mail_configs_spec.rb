# frozen_string_literal: true

RSpec.describe MailConfigs, type: :lib do
  include_context 'with isolated SMTP environment'

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
      account = create(:account, :paid, name: 'Tenant "Quoted" Name')
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

    it 'skips the pin of an account that is not entitled to per-account SMTP and keeps the row (D43)' do
      account = create(:account)
      pin = create_smtp_config(account)
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'

      result = described_class.resolve(account)

      expect(result.source).to eq(:env)
      expect(result.smtp[:address]).to eq('platform.smtp.example')
      expect(EncryptedConfig.exists?(pin.id)).to be(true)
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

    it 'bypasses the pin for platform notices, including when no platform server exists' do
      account = create(:account, :paid)
      create_smtp_config(account)

      expect(described_class.resolve(account, platform: true).source).to eq(:none)

      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
      ENV['SMTP_FROM'] = 'platform@example.com'

      expect(described_class.resolve(account, platform: true))
        .to have_attributes(source: :env, from: 'platform@example.com')
      expect(described_class.resolve(account).source).to eq(:account)
    end

    it 'returns none when neither account nor platform SMTP is configured' do
      result = described_class.resolve(create(:account))

      expect(result).to have_attributes(source: :none, smtp: {}, from: nil)
    end
  end

  describe 'testing-account inheritance' do
    it 'sends a test-mode child through the parent pinned server' do
      parent = create(:account, :internal, name: 'Parent Firm')
      testing_child = create(:account, :internal)
      parent.testing_accounts << testing_child
      create_smtp_config(parent)
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'

      result = described_class.resolve(testing_child.reload)

      expect(result.source).to eq(:account)
      expect(result.smtp).to include(address: 'pinned.smtp.example', user_name: 'pinned-user')
      expect(result.from).to eq('"Parent Firm" <tenant@example.com>')
    end

    it 'prefers the test-mode child own pin over the parent pin' do
      parent = create(:account, :internal, name: 'Parent Firm')
      testing_child = create(:account, :internal, name: 'Testing - Parent Firm')
      parent.testing_accounts << testing_child
      create_smtp_config(parent)
      create_smtp_config(testing_child, 'host' => 'child.smtp.example', 'from_email' => 'child@example.com')

      result = described_class.resolve(testing_child.reload)

      expect(result.source).to eq(:account)
      expect(result.smtp).to include(address: 'child.smtp.example')
      expect(result.from).to eq('"Testing - Parent Firm" <child@example.com>')
    end

    it 'leaves a non-testing linked child on the platform default' do
      parent = create(:account, :internal)
      linked_child = create(:account, :internal)
      AccountLinkedAccount.create!(account: parent, linked_account: linked_child, account_type: 'linked')
      create_smtp_config(parent)
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'

      expect(described_class.resolve(linked_child.reload).source).to eq(:env)
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

  describe 'incomplete account pins' do
    it 'falls through to the platform default when the pin lacks a host or from_email' do
      account = create(:account)
      create(:encrypted_config, account:, key: EncryptedConfig::EMAIL_SMTP_KEY, value: {})
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'

      result = described_class.resolve(account)

      expect(result.source).to eq(:env)
      expect(result.smtp[:address]).to eq('platform.smtp.example')
    end

    it 'reports :none for an incomplete pin with no platform default' do
      account = create(:account)
      create(:encrypted_config, account:, key: EncryptedConfig::EMAIL_SMTP_KEY, value: { 'host' => 'x.example' })

      expect(described_class.resolve(account).source).to eq(:none)
    end
  end

  describe EmailDeliveryConfig do
    before do
      ENV['EMAIL_DELIVERY_MODE'] = 'smtp'
    end

    it 'raises at boot in production when SMTP_ADDRESS is missing' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check! }
        .to raise_error(RuntimeError, /SMTP delivery mode but SMTP_ADDRESS is not set/)
    end

    it 'raises at boot in production when SMTP credentials are missing' do
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
      ENV['SMTP_FROM'] = 'EsignCenter <noreply@example.com>'
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check! }
        .to raise_error(RuntimeError, /SMTP credentials are not set/)
    end

    it 'raises at boot when production explicitly disables SMTP delivery' do
      ENV['EMAIL_DELIVERY_MODE'] = 'test'
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check! }
        .to raise_error(RuntimeError, /Production EMAIL_DELIVERY_MODE must be smtp/)
    end

    it 'raises at boot when production disables every SMTP encryption mode' do
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
      ENV['SMTP_FROM'] = 'EsignCenter <noreply@example.com>'
      ENV['SMTP_USERNAME'] = 'smtp-user'
      ENV['SMTP_PASSWORD'] = 'smtp-password'
      ENV['SMTP_ENABLE_STARTTLS'] = 'false'
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check! }
        .to raise_error(RuntimeError, /requires STARTTLS, SSL, or TLS/)
    end

    it 'raises at boot when production disables SMTP certificate verification' do
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
      ENV['SMTP_FROM'] = 'EsignCenter <noreply@example.com>'
      ENV['SMTP_USERNAME'] = 'smtp-user'
      ENV['SMTP_PASSWORD'] = 'smtp-password'
      ENV['SMTP_SSL_VERIFY'] = 'false'
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check! }
        .to raise_error(RuntimeError, /SMTP_SSL_VERIFY=false is not allowed/)
    end

    it 'allows production SMTP over direct TLS when STARTTLS is disabled' do
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
      ENV['SMTP_FROM'] = 'EsignCenter <noreply@example.com>'
      ENV['SMTP_USERNAME'] = 'smtp-user'
      ENV['SMTP_PASSWORD'] = 'smtp-password'
      ENV['SMTP_ENABLE_STARTTLS'] = 'false'
      ENV['SMTP_ENABLE_SSL'] = 'true'
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check! }.not_to raise_error
    end

    it 'raises at boot in production for an invalid explicit mode value' do
      ENV['EMAIL_DELIVERY_MODE'] = 'tes'
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check! }
        .to raise_error(RuntimeError, /EMAIL_DELIVERY_MODE=tes is invalid/)
    end

    it 'warns without raising in development when SMTP_ADDRESS is missing' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))
      allow(Rails.logger).to receive(:warn)

      expect { described_class.check! }.not_to raise_error
      expect(Rails.logger).to have_received(:warn)
        .with(/SMTP delivery mode but SMTP_ADDRESS is not set/)
    end
  end
end
