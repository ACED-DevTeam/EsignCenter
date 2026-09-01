# frozen_string_literal: true

RSpec.describe 'Tenant-isolated settings', type: :request do
  describe 'e-sign certificates' do
    let(:certificate_data) { GenerateCertificate.call.transform_values(&:to_pem) }
    let(:account_a) { create(:account) }
    let(:account_b) { create(:account) }

    before do
      create(:encrypted_config, account: account_a, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: certificate_data)
    end

    it 'loads an account own certificate and never returns it for another account' do
      account_a_pkcs = Accounts.load_signing_pkcs(account_a)

      expect(account_a_pkcs.certificate.to_pem).to eq(certificate_data.fetch(:cert))
      expect do
        Accounts.load_signing_pkcs(account_b)
      end.to raise_error(
        Accounts::MissingEsignCertsError,
        "Account #{account_b.id} has no e-sign certificates configured"
      )
    end

    it 'loads the parent certificate for a testing child' do
      testing_child = create(:account)
      account_a.testing_accounts << testing_child

      child_pkcs = Accounts.load_signing_pkcs(testing_child.reload)

      expect(child_pkcs.certificate.to_pem).to eq(certificate_data.fetch(:cert))
    end
  end

  describe 'timestamp servers' do
    it 'prefers the account value and then the environment value without using another account' do
      account = create(:account)
      another_account = create(:account)
      create(:encrypted_config, account: another_account, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                value: 'https://another-account.example.test')
      create(:encrypted_config, account:, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                value: 'https://account.example.test')
      stub_const('Docuseal::TIMESERVER_URL', 'https://environment.example.test')

      expect(Accounts.load_timeserver_url(account)).to eq('https://account.example.test')

      account.encrypted_configs.find_by!(key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY).destroy!

      expect(Accounts.load_timeserver_url(account)).to eq('https://environment.example.test')
    end
  end

  describe 'account configs' do
    it 'returns only the requested account config' do
      account_a = create(:account)
      account_b = create(:account)
      key = AccountConfig::WITH_SIGNATURE_ID
      create(:account_config, account: account_a, key:, value: true)

      expect(AccountConfigs.find_for_account(account_b, key)).to be_nil

      account_b_config = create(:account_config, account: account_b, key:, value: false)

      expect(AccountConfigs.find_for_account(account_b, key)).to eq(account_b_config)
    end
  end

  describe 'storage settings' do
    # The DB-driven storage screen is removed entirely: object storage is
    # configured only via environment variables, so no account of any kind
    # can reach or mutate a storage config over HTTP.
    it 'has no storage settings route for any account kind' do
      %i[operator internal].each do |kind|
        sign_in(create(:user, :admin, account: create(:account, kind)))

        expect { get '/settings/storage' }.to raise_error(ActionController::RoutingError)
        sign_out(:user)
      end

      sign_in(create(:user, :admin, account: create(:account)))

      expect { get '/settings/storage' }.to raise_error(ActionController::RoutingError)
    end
  end

  describe 'application URL' do
    it 'uses APP_URL and ignores an encrypted config row' do
      original_app_url = ENV.fetch('APP_URL', nil)
      ENV['APP_URL'] = 'https://environment.example.test:8443'
      stub_const('Docuseal::DEFAULT_APP_URL', ENV.fetch('APP_URL'))
      create(:encrypted_config, key: EncryptedConfig::APP_URL_KEY,
                                value: 'https://database.example.test')
      Docuseal.refresh_default_url_options!

      expect(Docuseal.default_url_options).to eq(
        host: 'environment.example.test', port: 8443, protocol: 'https'
      )
    ensure
      if original_app_url.nil?
        ENV.delete('APP_URL')
      else
        ENV['APP_URL'] = original_app_url
      end
      Docuseal.refresh_default_url_options!
    end
  end
end
