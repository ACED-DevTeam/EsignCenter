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

    it 'lets a testing child inherit the parent value but never a linked or unrelated account' do
      parent = create(:account, :internal)
      testing_child = create(:account, :internal)
      parent.testing_accounts << testing_child
      linked_child = create(:account, :internal)
      AccountLinkedAccount.create!(account: parent, linked_account: linked_child, account_type: 'linked')
      unrelated_account = create(:account)
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
    # The toggle writes an AccountConfig row onto the lowest-id account, so a
    # customer tenant reaching it would be a cross-tenant write.
    it 'refuses a customer admin and writes no config row anywhere' do
      create(:account, :internal)
      customer_admin = create(:user, :admin, account: create(:account))
      sign_in(customer_admin)

      expect do
        post settings_search_entries_reindex_index_path
      end.not_to change(AccountConfig.where(key: 'fulltext_search'), :count)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq('Search index rebuilds are unavailable for customer accounts')
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
    end

    it 'still lets an internal admin start the reindex' do
      sign_in(create(:user, :admin, account: create(:account, :internal)))

      post settings_search_entries_reindex_index_path

      expect(response).to have_http_status(:redirect)
      expect(AccountConfig.exists?(key: 'fulltext_search', value: true)).to be(true)
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
