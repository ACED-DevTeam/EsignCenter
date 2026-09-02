# frozen_string_literal: true

require 'rake'

# Customer accounts sign with the platform certificate even when they own a
# certificate row; internal accounts sign with their own; CERTS is gone; TSA
# failure is loud; cert/TSA management is operator-only.
#
# The platform certificate is ONE signing identity held by the operator
# account (lib/platform_certificate.rb). A customer's own esign_certs row — a
# legacy backfill or a provisioning leftover — is ignored on every signing
# path: the signed document, the combined PDF and the audit trail all carry
# the platform leaf. Internal accounts keep their own rows (console-managed),
# the operator falls back to the platform certificate, and with no operator
# account at all signing stops loudly instead of picking some other identity.
#
# A timestamp authority that cannot be reached fails the signing job (Sentry
# sees it, Sidekiq retries) instead of embedding a locally generated time, and
# certificates and the timestamp server can only be managed by the platform
# operator. See docs/operations.md.
RSpec.describe 'Platform certificate', type: :request do
  let!(:account) { create(:account) }
  let(:internal_account) { create(:account, :internal) }
  let(:internal_certificate_data) { GenerateCertificate.call.transform_values(&:to_pem) }
  let(:admins) { {} }

  def admin_for(account)
    admins[account.id] ||= create(:user, :admin, account:)
  end

  # A fresh integration session, then that account's admin (see gating_spec).
  def act_as(account)
    sign_out(:user)
    reset!
    sign_in(admin_for(account))
  end

  def enroll_two_factor(user)
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)

    user
  end

  def certify!(account, cert_data = GenerateCertificate.call.transform_values(&:to_pem))
    create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY, value: cert_data)
  end

  def text_template_for(account)
    create(:template, account:, author: admin_for(account), only_field_types: %w[text])
  end

  def emailed_submitter_for(account)
    template = text_template_for(account)
    submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))

    submission.submitters.first.tap { |submitter| submitter.update!(sent_at: Time.current) }
  end

  def text_field(submitter)
    fields = submitter.submission.template_fields.presence || submitter.submission.template.fields

    fields.find { |f| f['type'] == 'text' && f['submitter_uuid'] == submitter.uuid }
  end

  # The real interactive completion path, consent included (Phase A).
  def complete!(submitter)
    put "/s/#{submitter.slug}", params: { completed: 'true', esign_consent: 'true',
                                          values: { text_field(submitter)['uuid'] => 'Jane' } }

    expect(response).to have_http_status(:ok)

    submitter.reload
  end

  def signer_public_keys(bytes)
    HexaPDF::Document.new(io: StringIO.new(bytes)).signatures.map do |signature|
      signature.signature_handler.signer_certificate.public_key.to_der
    end
  end

  def public_key_of(pem)
    OpenSSL::X509::Certificate.new(pem).public_key.to_der
  end

  describe 'signing identity by account kind' do
    # THE Done-when: an account that owns a certificate row still signs with
    # the platform one, on every artefact a signer or a verifier ever sees.
    it 'signs a customer account documents with the platform certificate, never its own row', sidekiq: :inline do
      platform_certificate!
      own_certificate_data = GenerateCertificate.call.transform_values(&:to_pem)
      certify!(account, own_certificate_data)

      submitter = complete!(emailed_submitter_for(account))
      combined = Submissions::GenerateCombinedAttachment.call(submitter)

      platform_key = public_key_of(platform_certificate_pems.fetch('cert'))
      own_key = public_key_of(own_certificate_data.fetch(:cert))

      expect(platform_key).not_to eq(own_key)

      {
        'signed document' => submitter.documents.first.download,
        'audit trail' => submitter.submission.reload.audit_trail.download,
        'combined PDF' => combined.download
      }.each do |name, bytes|
        keys = signer_public_keys(bytes)

        expect(keys).to eq([platform_key]), name
        expect(keys).not_to include(own_key), name
      end
    end

    it 'signs an internal account with its own row and never with the platform certificate' do
      platform_certificate!
      certify!(internal_account, internal_certificate_data)

      pkcs = Accounts.load_signing_pkcs(internal_account)

      expect(pkcs.certificate.to_pem).to eq(internal_certificate_data.fetch(:cert))
      expect(pkcs.certificate.to_pem).not_to eq(platform_certificate_pems.fetch('cert'))
    end

    it 'lets a testing child of an internal account inherit the parent row' do
      platform_certificate!
      certify!(internal_account, internal_certificate_data)
      testing_child = create(:account, :internal)
      internal_account.testing_accounts << testing_child

      expect(Accounts.load_signing_pkcs(testing_child.reload).certificate.to_pem)
        .to eq(internal_certificate_data.fetch(:cert))
    end

    it 'signs an operator account with the platform certificate until it owns a row' do
      platform_row = platform_certificate!
      operator_account = platform_row.account

      expect(Accounts.load_signing_pkcs(operator_account).certificate.to_pem)
        .to eq(platform_certificate_pems.fetch('cert'))

      operator_certificate_data = GenerateCertificate.call.transform_values(&:to_pem)
      certify!(operator_account, operator_certificate_data)

      expect(Accounts.load_signing_pkcs(operator_account.reload).certificate.to_pem)
        .to eq(operator_certificate_data.fetch(:cert))
    end

    # A deployment without an operator account has no platform identity: it
    # must stop, not fall back to whatever row it can find.
    it 'refuses to sign a customer document with no operator account, and CERTS no longer exists' do
      expect(Account.exists?(account_kind: Account::OPERATOR_KIND)).to be(false)
      expect(Docuseal.const_defined?(:CERTS)).to be(false)

      submitter = complete!(emailed_submitter_for(account))

      expect do
        Accounts.load_signing_pkcs(account)
      end.to raise_error(OperatorConfigs::MissingOperatorAccountError, /rake operator:seed/)

      expect do
        Submissions::GenerateResultAttachments.call(submitter)
      end.to raise_error(OperatorConfigs::MissingOperatorAccountError)

      expect(submitter.documents.reload).to be_empty
    end
  end

  # What Phase C's public /verify will trust: the platform chain and the
  # chains internal (and operator) accounts signed with — never a customer's
  # ignored row, which never signed anything.
  describe 'platform verification certificates' do
    it 'collects the platform chain and internal chains but not a customer row' do
      platform_certificate!
      certify!(internal_account, internal_certificate_data)
      customer_certificate_data = GenerateCertificate.call.transform_values(&:to_pem)
      certify!(account, customer_certificate_data)

      pems = Accounts.platform_verification_certs.map(&:to_pem)

      expect(pems).to include(platform_certificate_pems.fetch('cert'))
      expect(pems).to include(platform_certificate_pems.fetch('root_ca'))
      expect(pems).to include(internal_certificate_data.fetch(:cert))
      expect(pems).not_to include(customer_certificate_data.fetch(:cert))
    end
  end

  describe 'timestamp server' do
    before { platform_certificate! }

    it 'ignores a customer row and uses the platform environment value' do
      create(:encrypted_config, account:, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                value: 'https://tenant.example.test/tsa')
      stub_const('Docuseal::TIMESERVER_URL', 'https://platform.example.test/tsa')

      expect(Accounts.load_timeserver_url(account)).to eq('https://platform.example.test/tsa')
    end

    it 'uses an internal account own row and falls back to the environment value' do
      create(:encrypted_config, account: internal_account, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                value: 'https://internal.example.test/tsa')
      stub_const('Docuseal::TIMESERVER_URL', 'https://platform.example.test/tsa')

      expect(Accounts.load_timeserver_url(internal_account)).to eq('https://internal.example.test/tsa')

      internal_account.encrypted_configs.find_by!(key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY).destroy!

      expect(Accounts.load_timeserver_url(internal_account.reload)).to eq('https://platform.example.test/tsa')
    end
  end

  describe 'a timestamp authority failure is loud' do
    let(:tsa_url) { 'http://tsa.test/rfc3161' }

    before do
      platform_certificate!
      stub_const('Docuseal::TIMESERVER_URL', tsa_url)
      allow(ErrorReport).to receive(:error)
    end

    # Before Session 4 a failing TSA silently embedded a locally generated
    # time that looked like a trusted timestamp. Now the signing job raises:
    # Sidekiq retries it and Sentry gets exactly one report.
    [
      ['an error response', -> { stub_request(:post, 'http://tsa.test/rfc3161').to_return(status: 500) }],
      ['a timeout', -> { stub_request(:post, 'http://tsa.test/rfc3161').to_timeout }]
    ].each do |description, build_stub|
      it "fails the signing job on #{description} and writes no signed PDF" do
        instance_exec(&build_stub)

        submitter = complete!(emailed_submitter_for(account))

        expect do
          Submissions::GenerateResultAttachments.call(submitter)
        end.to raise_error(Submissions::TimestampHandler::TimestampError, /#{Regexp.escape(tsa_url)}/)

        expect(submitter.documents.reload).to be_empty
        expect(ErrorReport).to have_received(:error)
          .with(instance_of(Submissions::TimestampHandler::TimestampError)).once
      end
    end
  end

  describe 'certificate and timestamp-server management is operator-only' do
    let(:operator_account) { create(:account, :operator) }
    let(:operator) do
      enroll_two_factor(create(:user, :admin, account: operator_account, platform_operator: true))
    end

    def esign_cert_config_rows
      EncryptedConfig.where(key: EncryptedConfig::ESIGN_CERTS_KEY)
    end

    def timestamp_config_rows
      EncryptedConfig.where(key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY)
    end

    [
      ['a customer admin', -> { account }],
      ['a paid customer admin', -> { create(:account, :paid) }],
      ['an internal admin', -> { create(:account, :internal) }]
    ].each do |description, build_account|
      it "has no certificate or timestamp-server management route for #{description}" do
        operator_account
        act_as(instance_exec(&build_account))

        expect { get new_settings_esign_path }.to raise_error(ActionController::RoutingError)
        expect { post settings_esign_path }.to raise_error(ActionController::RoutingError)
        expect { patch settings_esign_path, params: { name: 'x' } }.to raise_error(ActionController::RoutingError)
        expect { put settings_esign_path, params: { name: 'x' } }.to raise_error(ActionController::RoutingError)
        expect { delete settings_esign_path, params: { name: 'x' } }.to raise_error(ActionController::RoutingError)
        expect do
          post timestamp_server_index_path, params: { encrypted_config: { value: 'https://tsa.example.test/' } }
        end.to raise_error(ActionController::RoutingError)

        expect(esign_cert_config_rows).not_to exist
        expect(timestamp_config_rows).not_to exist
      end
    end

    it 'shows an account admin the preferences only, never the certificate or timestamp-server surfaces' do
      operator_account
      act_as(account)

      get settings_esign_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('preferences'))
      expect(response.body).to include(I18n.t('remove_pdf_form_fillable_fields_from_the_signed_pdf_flatten_form'))
      expect(response.body).to include(I18n.t('document_download_filename_format'))
      expect(response.body).not_to include(I18n.t('signing_certificates'))
      expect(response.body).not_to include(I18n.t('timestamp_server'))
      expect(response.body).not_to include(I18n.t('verify_signed_pdf'))
      expect(response.body).not_to include(new_settings_esign_path)
      expect(response.body).not_to include(verify_pdf_signature_index_path)
    end

    it 'shows the operator the certificate table, the upload button and the timestamp-server form' do
      sign_in(operator)

      get settings_esign_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('signing_certificates'))
      expect(response.body).to include(I18n.t('timestamp_server'))
      expect(response.body).to include(I18n.t('verify_signed_pdf'))
      expect(response.body).to include(new_settings_esign_path)
      expect(response.body).to include(I18n.t('preferences'))
    end

    it 'lets the operator open the upload form and save a timestamp server' do
      stub_request(:post, 'https://tsa.example.test/').to_return(status: 200, body: 'timestamp-response')
      sign_in(operator)

      get new_settings_esign_path

      expect(response).to have_http_status(:ok)

      post timestamp_server_index_path, params: { encrypted_config: { value: 'https://tsa.example.test/' } },
                                        headers: { 'HTTP_REFERER' => settings_esign_path }

      expect(response).to redirect_to(settings_esign_path)
      expect(timestamp_config_rows.sole.account).to eq(operator_account)
      expect(Accounts.load_timeserver_url(operator_account)).to eq('https://tsa.example.test/')
    end

    it 'refuses an anonymous visitor without revealing the surface' do
      expect { get new_settings_esign_path }.to raise_error(ActionController::RoutingError)
      expect do
        post timestamp_server_index_path, params: { encrypted_config: { value: 'https://tsa.example.test/' } }
      end.to raise_error(ActionController::RoutingError)

      expect(EncryptedConfig.count).to eq(0)
    end
  end

  describe 'operator rake tasks' do
    stash_env('OPERATOR_EMAIL', 'OPERATOR_PASSWORD')

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('operator:seed')
      ENV['OPERATOR_EMAIL'] = 'golden-platform-cert@example.com'
      ENV['OPERATOR_PASSWORD'] = 'golden-platform-cert-password'
    end

    after do
      Rake::Task['operator:seed'].reenable
      Rake::Task['operator:platform_cert:export'].reenable
    end

    def platform_rows
      EncryptedConfig.where(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_KEY)
    end

    it 'seeds exactly one platform certificate row however often it runs' do
      expect { Rake::Task['operator:seed'].invoke }.to output(/Created operator account/).to_stdout

      row = platform_rows.sole
      original_value = row.value

      expect(row.account).to eq(OperatorConfigs.account)
      expect(row.value['cert']).to include('BEGIN CERTIFICATE')

      Rake::Task['operator:seed'].reenable

      expect { Rake::Task['operator:seed'].invoke }.to output(/already exists/).to_stdout

      expect(platform_rows.sole.value).to eq(original_value)
    end

    it 'exports a 0600 custody bundle and prints no key material' do
      path = Rails.root.join("tmp/platform-cert-#{SecureRandom.hex(4)}.pem").to_s
      platform_row = platform_certificate!

      output = capture_stdout do
        Rake::Task['operator:platform_cert:export'].execute(Rake::TaskArguments.new([:path], [path]))
      end

      bundle = File.read(path)

      expect(format('%o', File::Stat.new(path).mode)).to end_with('600')
      expect(bundle).to include('BEGIN CERTIFICATE')
      expect(bundle).to match(/BEGIN (RSA )?PRIVATE KEY/)
      expect(bundle).to include(platform_row.value.fetch('cert'))

      expect(output).to include(PlatformCertificate.fingerprint)
      expect(output).to include("#{File.size(path)} bytes")
      expect(output).not_to include('PRIVATE KEY')
      expect(output).not_to include('BEGIN CERTIFICATE')
    ensure
      FileUtils.rm_f(path)
    end

    it 'prints only the fingerprint of the platform certificate' do
      platform_certificate!

      output = capture_stdout { Rake::Task['operator:platform_cert:fingerprint'].execute }

      expect(output.strip).to eq(PlatformCertificate.fingerprint)
      expect(output).to match(/\A(\h{2}:){31}\h{2}\n\z/)
    end

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end
  end
end
