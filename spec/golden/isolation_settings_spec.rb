# frozen_string_literal: true

RSpec.describe 'Tenant-isolated settings', type: :request do
  # Session 4: a customer account never signs with a certificate row of its
  # own — the platform certificate is the ONE customer signing identity — while
  # an internal account keeps its own row and can never reach another
  # account's. The same split governs the timestamp server.
  describe 'e-sign certificates' do
    let(:internal_certificate_data) { GenerateCertificate.call.transform_values(&:to_pem) }
    let(:internal_account) { create(:account, :internal) }
    let(:customer_account) { create(:account) }

    before do
      platform_certificate!
      create(:encrypted_config, account: internal_account, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: internal_certificate_data)
    end

    it 'loads an internal account own certificate' do
      internal_pkcs = Accounts.load_signing_pkcs(internal_account)

      expect(internal_pkcs.certificate.to_pem).to eq(internal_certificate_data.fetch(:cert))
    end

    it 'loads the parent certificate for an internal testing child' do
      testing_child = create(:account, :internal)
      internal_account.testing_accounts << testing_child

      child_pkcs = Accounts.load_signing_pkcs(testing_child.reload)

      expect(child_pkcs.certificate.to_pem).to eq(internal_certificate_data.fetch(:cert))
    end

    it 'never lends one internal account certificate to another: a bare internal account raises' do
      bare_internal = create(:account, :internal)

      expect do
        Accounts.load_signing_pkcs(bare_internal)
      end.to raise_error(
        Accounts::MissingEsignCertsError,
        "Account #{bare_internal.id} has no e-sign certificates configured"
      )
    end

    it 'signs a customer account with the platform certificate and ignores its own row' do
      own_certificate_data = GenerateCertificate.call.transform_values(&:to_pem)
      create(:encrypted_config, account: customer_account, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: own_certificate_data)

      customer_pkcs = Accounts.load_signing_pkcs(customer_account)

      expect(customer_pkcs.certificate.to_pem).to eq(platform_certificate_pems.fetch('cert'))
      expect(customer_pkcs.certificate.to_pem).not_to eq(own_certificate_data.fetch(:cert))
      expect(customer_pkcs.certificate.to_pem).not_to eq(internal_certificate_data.fetch(:cert))
    end

    it 'trusts the platform chain for a customer and adds the own chain only for an internal account' do
      customer_certs = Accounts.load_trusted_certs(customer_account).map(&:to_pem)
      internal_certs = Accounts.load_trusted_certs(internal_account).map(&:to_pem)

      expect(customer_certs).to include(platform_certificate_pems.fetch('cert'))
      expect(customer_certs).not_to include(internal_certificate_data.fetch(:cert))
      expect(internal_certs).to include(platform_certificate_pems.fetch('cert'),
                                        internal_certificate_data.fetch(:cert))
    end
  end

  describe 'timestamp servers' do
    it 'ignores a customer account row and uses the platform environment value' do
      account = create(:account)
      create(:encrypted_config, account:, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                value: 'https://account.example.test')
      stub_const('Docuseal::TIMESERVER_URL', 'https://environment.example.test')

      expect(Accounts.load_timeserver_url(account)).to eq('https://environment.example.test')
    end

    it 'prefers an internal account own value and then the environment value without using another account' do
      account = create(:account, :internal)
      another_account = create(:account, :internal)
      create(:encrypted_config, account: another_account, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                value: 'https://another-account.example.test')
      create(:encrypted_config, account:, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                value: 'https://account.example.test')
      stub_const('Docuseal::TIMESERVER_URL', 'https://environment.example.test')

      expect(Accounts.load_timeserver_url(account)).to eq('https://account.example.test')

      account.encrypted_configs.find_by!(key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY).destroy!

      expect(Accounts.load_timeserver_url(account)).to eq('https://environment.example.test')
    end

    it 'lets a testing child inherit the parent value but never a linked or unrelated account' do
      parent = create(:account, :internal)
      testing_child = create(:account, :internal)
      parent.testing_accounts << testing_child
      linked_child = create(:account, :internal)
      AccountLinkedAccount.create!(account: parent, linked_account: linked_child, account_type: 'linked')
      unrelated_account = create(:account, :internal)
      create(:encrypted_config, account: parent, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                value: 'https://parent.example.test')
      stub_const('Docuseal::TIMESERVER_URL', 'https://environment.example.test')

      expect(Accounts.load_timeserver_url(testing_child.reload)).to eq('https://parent.example.test')
      expect(Accounts.load_timeserver_url(linked_child.reload)).to eq('https://environment.example.test')
      expect(Accounts.load_timeserver_url(unrelated_account)).to eq('https://environment.example.test')
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

  describe 'signed PDF e-signing preference' do
    # Exercises the real production method. Each submission has a second,
    # still-pending signer, so the "last signer of a fully completed submission"
    # branch is unreachable: the only way to get a non-nil reason is the
    # per-signer branch, which is taken only when the SUBMITTER'S OWN account
    # (or, for a testing child, its parent) holds the 'multiple' preference.
    # One tenant setting 'multiple' must never change another tenant's
    # signed-PDF Reason field.
    def build_completed_submitter_with_pending_peer(account)
      create(:user, account:) # the template's default folder needs an author in this account
      template = create(:template, account:, attachment_count: 0, submitter_count: 2)
      submission = create(:submission, template:)
      create(:submitter, submission:, uuid: template.submitters.second['uuid'])

      create(:submitter, submission:, uuid: template.submitters.first['uuid'], completed_at: Time.current)
    end

    it 'derives the signed-PDF reason from the submitter own account only' do
      account_a = create(:account)
      account_b = create(:account)
      create(:account_config, account: account_a, key: AccountConfig::ESIGNING_PREFERENCE_KEY, value: 'multiple')

      submitter_a = build_completed_submitter_with_pending_peer(account_a)
      submitter_b = build_completed_submitter_with_pending_peer(account_b)

      expect(Submissions::GenerateResultAttachments.fetch_sign_reason(submitter_a))
        .to eq(Submissions::GenerateResultAttachments.sign_reason(submitter_a.email))
      expect(Submissions::GenerateResultAttachments.fetch_sign_reason(submitter_b)).to be_nil

      create(:account_config, account: account_b, key: AccountConfig::ESIGNING_PREFERENCE_KEY, value: 'multiple')

      expect(Submissions::GenerateResultAttachments.fetch_sign_reason(submitter_b.reload))
        .to eq(Submissions::GenerateResultAttachments.sign_reason(submitter_b.email))
    end

    it 'lets a testing child inherit the parent preference' do
      parent = create(:account, :internal)
      testing_child = create(:account, :internal)
      parent.testing_accounts << testing_child
      create(:account_config, account: parent, key: AccountConfig::ESIGNING_PREFERENCE_KEY, value: 'multiple')

      child_submitter = build_completed_submitter_with_pending_peer(testing_child.reload)

      expect(Submissions::GenerateResultAttachments.fetch_sign_reason(child_submitter))
        .to eq(Submissions::GenerateResultAttachments.sign_reason(child_submitter.email))
    end
  end

  describe 'fulltext search reindex' do
    # The toggle is an instance-global row on the operator account, so it is an
    # operator surface: a tenant admin of any kind gets a 404 (the route does
    # not exist for them) and no config row is written anywhere. The operator
    # positive control lives in operator_access_spec.
    it 'refuses a customer admin and writes no config row anywhere' do
      create(:account, :operator)
      customer_admin = create(:user, :admin, account: create(:account))
      sign_in(customer_admin)

      expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
    end

    it 'refuses an internal admin the same way' do
      create(:account, :operator)
      sign_in(create(:user, :admin, account: create(:account, :internal)))

      expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
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

  describe 'storage loader' do
    # Object storage is environment-only. A leftover (or newly written)
    # active_storage row on the lowest-id account — the row the old loader
    # read for the whole instance — must not change the service any tenant's
    # files are written to.
    it 'ignores a lowest-id account storage row and keeps the environment-selected service' do
      lowest_account = create(:account)
      expect(Account.minimum(:id)).to eq(lowest_account.id)
      create(:encrypted_config, account: lowest_account, key: EncryptedConfig::FILES_STORAGE_KEY,
                                value: {
                                  'service' => 'aws_s3',
                                  'configs' => {
                                    'access_key_id' => 'AKIAGOLDENTENANT',
                                    'secret_access_key' => 'golden-tenant-secret',
                                    'region' => 'us-east-1',
                                    'bucket' => 'golden-tenant-bucket',
                                    'endpoint' => 'https://storage.golden-tenant.example'
                                  }
                                })
      service_before = ActiveStorage::Blob.service

      LoadActiveStorageConfigs.reload
      LoadActiveStorageConfigs.call

      expect(ActiveStorage::Blob.service).to equal(service_before)
      expect(ActiveStorage::Blob.service).to be_a(ActiveStorage::Service::DiskService)
      expect(Rails.application.config.active_storage.service).to eq(:test)
    end
  end

  describe 'application URL' do
    # The environment is the only source: APP_URL, then HOST (+ FORCE_SSL),
    # then the local default. There is no database setting any more, and a
    # leftover app_url row from before the removal is inert.
    def url_env_keys
      %w[APP_URL HOST FORCE_SSL]
    end

    around do |example|
      original_values = url_env_keys.index_with { |key| ENV.fetch(key, nil) }

      example.run
    ensure
      original_values.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
      Docuseal.refresh_default_url_options!
    end

    def url_options_with(env)
      url_env_keys.each { |key| ENV.delete(key) }
      env.each { |key, value| ENV[key] = value }
      Docuseal.refresh_default_url_options!

      Docuseal.default_url_options
    end

    it 'uses APP_URL and ignores a legacy app_url row' do
      create(:encrypted_config, key: 'app_url', value: 'https://database.example.test')

      expect(url_options_with('APP_URL' => 'https://environment.example.test:8443',
                              'HOST' => 'ignored.example.test')).to eq(
                                host: 'environment.example.test', port: 8443, protocol: 'https'
                              )
    end

    it 'falls back to HOST with FORCE_SSL selecting https' do
      expect(url_options_with('HOST' => 'host.example.test')).to eq(host: 'host.example.test', protocol: 'http')
      expect(url_options_with('HOST' => 'host.example.test', 'FORCE_SSL' => 'true'))
        .to eq(host: 'host.example.test', protocol: 'https')
    end

    # Local development may deliberately opt out; production refuses to boot
    # with this value before any generated HTTP link can leave the service.
    it 'treats FORCE_SSL=false as http for local development' do
      expect(url_options_with('HOST' => 'host.example.test', 'FORCE_SSL' => 'false'))
        .to eq(host: 'host.example.test', protocol: 'http')
      expect(url_options_with('HOST' => 'host.example.test', 'FORCE_SSL' => 'true'))
        .to eq(host: 'host.example.test', protocol: 'https')
    end

    it 'keeps a HOST that carries its own port' do
      expect(url_options_with('HOST' => 'localhost:3015')).to eq(host: 'localhost:3015', protocol: 'http')
    end

    it 'defaults to localhost:3000 when neither APP_URL nor HOST is set' do
      expect(url_options_with({})).to eq(host: 'localhost', port: 3000, protocol: 'http')
    end

    # With no environment value at all, a legacy database row is the only
    # candidate left — and it must still not be read.
    it 'ignores a legacy app_url row when no environment value could mask it' do
      create(:encrypted_config, key: 'app_url', value: 'https://database.example.test')

      expect(url_options_with({})).to eq(host: 'localhost', port: 3000, protocol: 'http')
    end
  end
end
