# frozen_string_literal: true

RSpec.describe ProductionReadiness, type: :lib do
  let(:required_env) do
    {
      'DATABASE_URL' => 'postgres://example',
      'SECRET_KEY_BASE' => 'secret',
      'HOST' => 'esigncenter.example',
      'FORCE_SSL' => 'true',
      'ADMIN_PROVISION_TOKEN' => 'provision-token',
      'TIMESERVER_URL' => 'https://timestamp.example',
      'SMTP_ADDRESS' => 'smtp.example',
      'SMTP_FROM' => 'EsignCenter <noreply@example.com>',
      'SMTP_USERNAME' => 'smtp-user',
      'SMTP_PASSWORD' => 'smtp-password',
      'REGISTRATION_ENABLED' => 'false',
      'BILLING_ENABLED' => 'false'
    }
  end

  describe '.checks' do
    it 'passes a configured dark deploy without exposing any value' do
      checks = described_class.checks(required_env)

      expect(checks).to all(have_attributes(ok: true))
      expect(checks.map(&:message).join).not_to include(
        'postgres://example', 'secret', 'provision-token', 'smtp-password'
      )
    end

    it 'names missing production requirements and refuses enabled launch switches' do
      env = required_env.merge(
        'FORCE_SSL' => 'false',
        'TIMESERVER_URL' => nil,
        'SMTP_PASSWORD' => nil,
        'REGISTRATION_ENABLED' => 'true'
      )

      expect(described_class.failures(env).map(&:name))
        .to contain_exactly('FORCE_SSL', 'TIMESERVER_URL', 'SMTP_CREDENTIALS', 'REGISTRATION_ENABLED')
    end

    it 'accepts APP_URL instead of HOST only when it is an HTTPS origin' do
      valid = required_env.merge('HOST' => nil, 'APP_URL' => 'https://esigncenter.example:8443/')
      invalid = valid.merge('APP_URL' => 'http://user:pass@esigncenter.example/path?x=1#fragment')

      expect(described_class.failures(valid)).to be_empty
      expect(described_class.failures(invalid).map(&:name)).to include('APP_URL')
    end

    it 'rejects the public provisioning placeholder and production test-mail mode' do
      env = required_env.merge('ADMIN_PROVISION_TOKEN' => 'dev_prov_public', 'EMAIL_DELIVERY_MODE' => 'test')

      expect(described_class.failures(env).map(&:name))
        .to contain_exactly('ADMIN_PROVISION_TOKEN', 'EMAIL_DELIVERY_MODE')
    end

    it 'accepts the approved HTTP DigiCert TSA and rejects malformed timestamp values' do
      valid = required_env.merge('TIMESERVER_URL' => 'http://timestamp.digicert.com')
      invalid = required_env.merge('TIMESERVER_URL' => 'timestamp.digicert.com')

      expect(described_class.failures(valid)).to be_empty
      expect(described_class.failures(invalid).map(&:name)).to eq(['TIMESERVER_URL'])
    end

    it 'accepts POSTMARK_API_TOKEN instead of a username/password pair' do
      env = required_env.merge('SMTP_USERNAME' => nil, 'SMTP_PASSWORD' => nil,
                               'POSTMARK_API_TOKEN' => 'postmark-token')

      expect(described_class.failures(env)).to be_empty
      expect(described_class.checks(env).map(&:message).join).not_to include('postmark-token')
    end

    it 'rejects an unencrypted platform SMTP transport or disabled certificate verification' do
      env = required_env.merge('SMTP_ENABLE_STARTTLS' => 'false', 'SMTP_SSL_VERIFY' => 'false')

      expect(described_class.failures(env).map(&:name))
        .to contain_exactly('SMTP_TRANSPORT_ENCRYPTION', 'SMTP_CERTIFICATE_VERIFICATION')
    end

    it 'accepts direct SMTP TLS when STARTTLS is disabled' do
      env = required_env.merge('SMTP_ENABLE_STARTTLS' => 'false', 'SMTP_ENABLE_TLS' => 'true')

      expect(described_class.failures(env)).to be_empty
    end
  end

  describe '.check_boot!' do
    it 'refuses a production boot unless FORCE_SSL is exactly true' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

      expect { described_class.check_boot!(required_env.merge('FORCE_SSL' => nil)) }
        .to raise_error(RuntimeError, /FORCE_SSL must be exactly true/)
      expect { described_class.check_boot!(required_env) }.not_to raise_error
    end

    it 'refuses malformed APP_URL, TSA and the development provisioning token in production' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))
      env = required_env.merge('APP_URL' => 'http://esigncenter.example/path',
                               'TIMESERVER_URL' => 'not a URL',
                               'ADMIN_PROVISION_TOKEN' => 'dev_prov_public')

      expect { described_class.check_boot!(env) }
        .to raise_error(RuntimeError, /APP_URL.*TIMESERVER_URL/)
    end

    it 'does not constrain local development' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))

      expect { described_class.check_boot!({}) }.not_to raise_error
    end
  end
end
