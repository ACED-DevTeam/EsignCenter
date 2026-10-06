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
# A rotation retires the current chain (kept forever for verification) and
# generates a new identity; no read path ever generates the certificate. A
# timestamp authority that cannot be reached — after every configured URL was
# tried — fails the signing job (reported once, Sidekiq retries) instead of
# embedding a locally generated time, and certificates and the timestamp
# server can only be managed by the platform operator. See docs/operations.md.
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

    # A customer's testing child copies the customer kind, so the parent's
    # own row is as irrelevant to it as to the parent.
    it 'signs a customer testing child with the platform certificate, never the parent own row' do
      platform_certificate!
      own_certificate_data = GenerateCertificate.call.transform_values(&:to_pem)
      certify!(account, own_certificate_data)
      admin_for(account)

      child = Accounts.find_or_create_testing_user(account).account

      expect(child).not_to eq(account)
      expect(child.customer?).to be(true)
      expect(account.reload.testing_accounts).to include(child)

      pem = Accounts.load_signing_pkcs(child).certificate.to_pem

      expect(pem).to eq(platform_certificate_pems.fetch('cert'))
      expect(pem).not_to eq(own_certificate_data.fetch(:cert))
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

    # TRUSTED_CERTS helps build a chain; it never makes a signature ours.
    it 'keeps the environment chain out of the signer set' do
      platform_certificate!
      env_cert = GenerateCertificate.call('Env').fetch(:cert)
      allow(Docuseal).to receive(:trusted_certs).and_return([env_cert])

      expect(Accounts.platform_verification_certs.map(&:to_pem)).to include(env_cert.to_pem)
      expect(Accounts.platform_signer_certs.map(&:to_pem)).not_to include(env_cert.to_pem)
      expect(Accounts.platform_signer_certs.map(&:to_pem)).to include(platform_certificate_pems.fetch('cert'))
    end

    it 'reads nothing into existence: no row and no operator account both answer an empty platform chain' do
      expect(Account.exists?(account_kind: Account::OPERATOR_KIND)).to be(false)

      expect { expect(Accounts.platform_verification_certs).to eq([]) }.not_to change(EncryptedConfig, :count)
      expect { expect(Accounts.load_trusted_certs(account)).to eq([]) }.not_to change(EncryptedConfig, :count)

      create(:account, :operator)

      expect { expect(PlatformCertificate.current_chain).to eq([]) }.not_to change(EncryptedConfig, :count)
      expect { expect(Accounts.platform_signer_certs).to eq([]) }.not_to change(EncryptedConfig, :count)
      expect { PlatformCertificate.fingerprint }.to raise_error(PlatformCertificate::MissingCertificateError, /seed/)
    end
  end

  describe 'rotation' do
    it 'retires the current chain, signs with a fresh one and keeps the retired chain trusted' do
      platform_row = platform_certificate!
      old_pems = platform_row.value
      old_key = public_key_of(old_pems.fetch('cert'))

      expect(Accounts.load_signing_pkcs(account).certificate.public_key.to_der).to eq(old_key)

      old_fingerprint, new_fingerprint = PlatformCertificate.rotate!

      expect(old_fingerprint).to eq(PlatformCertificate.fingerprint(old_pems.fetch('cert')))
      expect(new_fingerprint).to eq(PlatformCertificate.fingerprint)
      expect(new_fingerprint).not_to eq(old_fingerprint)

      current_rows = EncryptedConfig.where(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_KEY)
      expect(current_rows.count).to eq(1)
      expect(current_rows.sole.value.fetch('cert')).not_to eq(old_pems.fetch('cert'))

      retired = EncryptedConfig.find_by!(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_RETIRED_KEY).value
      expect(retired.size).to eq(1)
      expect(retired.sole).to include('cert' => old_pems.fetch('cert'), 'sub_ca' => old_pems.fetch('sub_ca'),
                                      'root_ca' => old_pems.fetch('root_ca'))
      expect(retired.sole['retired_at']).to be_present
      expect(retired.sole.keys).not_to include('key', 'sub_key', 'root_key')

      # New signatures use the new leaf (the memo did not survive the rotation) …
      new_key = public_key_of(current_rows.sole.value.fetch('cert'))
      expect(Accounts.load_signing_pkcs(account).certificate.public_key.to_der).to eq(new_key)
      expect(new_key).not_to eq(old_key)

      # … and every verifier still trusts the retired chain.
      expect(PlatformCertificate.retired_chains.map(&:to_pem))
        .to include(old_pems.fetch('cert'), old_pems.fetch('root_ca'))
      expect(Accounts.platform_signer_certs.map(&:to_pem)).to include(old_pems.fetch('cert'))
      expect(Accounts.load_trusted_certs(account).map(&:to_pem)).to include(old_pems.fetch('cert'))

      PlatformCertificate.rotate!

      expect(EncryptedConfig.find_by!(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_RETIRED_KEY).value.size).to eq(2)
      expect(current_rows.count).to eq(1)
    end

    it 'refuses to rotate what was never seeded' do
      create(:account, :operator)

      expect { PlatformCertificate.rotate! }.to raise_error(PlatformCertificate::MissingCertificateError, /seed/)
      expect(EncryptedConfig.count).to eq(0)
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

    # A self-signed timestamping certificate and a real RFC 3161 response for
    # the request the handler sends, so the third authority can answer.
    let(:tsa_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:tsa_cert) do
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=Golden TSA')
      cert.public_key = tsa_key.public_key
      cert.not_before = 1.minute.ago
      cert.not_after = 1.hour.from_now
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = extensions.issuer_certificate = cert
      cert.add_extension(extensions.create_extension('extendedKeyUsage', 'timeStamping', true))
      cert.add_extension(extensions.create_extension('basicConstraints', 'CA:FALSE', true))
      cert.sign(tsa_key, 'sha256')
    end

    before do
      platform_certificate!
      stub_const('Docuseal::TIMESERVER_URL', tsa_url)
      allow(ErrorReport).to receive(:error)
    end

    def timestamp_response_for(request_der)
      factory = OpenSSL::Timestamp::Factory.new
      # OpenSSL wants a plain Time, not a TimeWithZone, and rejects the
      # request with BAD_ALG unless its digest is explicitly allowed.
      factory.gen_time = Time.current.to_time
      factory.serial_number = 1
      factory.default_policy_id = '1.2.3.4.5'
      factory.allowed_digests = [Submissions::TimestampHandler::HASH_ALGORITHM.downcase]

      factory.create_timestamp(tsa_key, tsa_cert, OpenSSL::Timestamp::Request.new(request_der)).to_der
    end

    # Before Session 4 a failing TSA silently embedded a locally generated
    # time that looked like a trusted timestamp. Now the signing job raises,
    # and the job's own rescue (EnsureResultGenerated) reports it exactly
    # once — the handler does not report on its own.
    [
      ['an error response', -> { stub_request(:post, 'http://tsa.test/rfc3161').to_return(status: 500) }],
      ['a timeout', -> { stub_request(:post, 'http://tsa.test/rfc3161').to_timeout }]
    ].each do |description, build_stub|
      it "fails the signing job on #{description}, writes no signed PDF and reports once" do
        instance_exec(&build_stub)

        submitter = complete!(emailed_submitter_for(account))

        expect do
          Submissions::EnsureResultGenerated.call(submitter)
        end.to raise_error(Submissions::TimestampHandler::TimestampError, /#{Regexp.escape(tsa_url)}/)

        expect(submitter.documents.reload).to be_empty
        expect(ErrorReport).to have_received(:error)
          .with(instance_of(Submissions::TimestampHandler::TimestampError)).once
      end
    end

    it 'tries every configured authority in order and signs with the first one that answers' do
      stub_const('Docuseal::TIMESERVER_URL',
                 'http://tsa-a.test/rfc3161, http://tsa-b.test/rfc3161 ,http://tsa-c.test/rfc3161')
      stub_request(:post, 'http://tsa-a.test/rfc3161').to_return(status: 500)
      stub_request(:post, 'http://tsa-b.test/rfc3161').to_timeout
      stub_request(:post, 'http://tsa-c.test/rfc3161')
        .to_return { |request| { status: 200, body: timestamp_response_for(request.body) } }

      submitter = complete!(emailed_submitter_for(account))

      documents = Submissions::EnsureResultGenerated.call(submitter)

      expect(documents).not_to be_empty
      expect(submitter.documents.reload).not_to be_empty
      expect(signer_public_keys(submitter.documents.first.download))
        .to eq([public_key_of(platform_certificate_pems.fetch('cert'))])

      expect(WebMock).to have_requested(:post, 'http://tsa-a.test/rfc3161').at_least_once
      expect(WebMock).to have_requested(:post, 'http://tsa-b.test/rfc3161').at_least_once
      expect(WebMock).to have_requested(:post, 'http://tsa-c.test/rfc3161').at_least_once
      expect(ErrorReport).not_to have_received(:error)
    end

    it 'gives up only after the last configured authority failed' do
      stub_const('Docuseal::TIMESERVER_URL', 'http://tsa-a.test/rfc3161,http://tsa-b.test/rfc3161,http://tsa-c.test/rfc3161')
      %w[a b c].each { |name| stub_request(:post, "http://tsa-#{name}.test/rfc3161").to_return(status: 503) }

      submitter = complete!(emailed_submitter_for(account))

      expect { Submissions::EnsureResultGenerated.call(submitter) }
        .to raise_error(Submissions::TimestampHandler::TimestampError, /tsa-a\.test.*tsa-b\.test.*tsa-c\.test/)

      %w[a b c].each { |name| expect(WebMock).to have_requested(:post, "http://tsa-#{name}.test/rfc3161").once }
      expect(submitter.documents.reload).to be_empty
      expect(ErrorReport).to have_received(:error).once
    end
  end

  describe 'certificate and timestamp-server management is operator-only' do
    # Seed the certificate on the same operator that signs in below. Otherwise
    # platform_certificate! creates a second operator before this lazy fixture.
    let!(:operator_account) { create(:account, :operator) }
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
      platform_certificate!
      act_as(account)

      get settings_esign_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('preferences'))
      expect(response.body).to include(I18n.t('remove_pdf_form_fillable_fields_from_the_signed_pdf_flatten_form'))
      expect(response.body).to include(I18n.t('document_download_filename_format'))
      expect(response.body).not_to include(I18n.t('signing_certificates'))
      expect(response.body).not_to include(I18n.t('timestamp_server'))
      expect(response.body).not_to include(new_settings_esign_path)
      # Signature checking is the public /verify page now (Phase C): every
      # admin gets the card linking there, nobody gets an in-app dropzone.
      expect(response.body).to include(verify_path)
      expect(response.body).not_to include('name="files[]"')
      # The platform identity is the operator's to see, nobody else's.
      expect(response.body).not_to include(I18n.t('platform_signing_certificate'))
      expect(response.body).not_to include(PlatformCertificate.fingerprint)
    end

    it 'shows the operator the platform certificate read-only, then this account certificates and the TSA form' do
      platform_certificate!
      sign_in(operator)

      get settings_esign_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('signing_certificates'))
      expect(response.body).to include(I18n.t('platform_signing_certificate'))
      expect(response.body).to include(PlatformCertificate.fingerprint)
      expect(response.body).to include(I18n.t('platform_certificate_used_by_every_customer_account'))
      leaf = OpenSSL::X509::Certificate.new(platform_certificate_pems.fetch('cert'))
      expect(response.body).to include(I18n.l(leaf.not_after.to_date, format: :long, locale: operator_account.locale))
      # ERB escapes the apostrophe in the label.
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('this_account_certificates')))
      expect(response.body).to include(I18n.t('this_account_certificates_hint'))
      expect(response.body).to include(I18n.t('timestamp_server'))
      expect(response.body).to include(I18n.t('timestamp_server_operator_only_hint'))
      expect(response.body).to include(verify_path)
      expect(response.body).to include(new_settings_esign_path)
      expect(response.body).to include(I18n.t('preferences'))
    end

    it 'tells the operator to seed when there is no platform certificate yet, without creating one' do
      sign_in(operator)

      expect { get settings_esign_path }.not_to change(EncryptedConfig, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('platform_certificate_not_generated_yet'))
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
      Rake::Task['operator:platform_cert:rotate'].reenable
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

    it 'refuses to export or print a certificate that does not exist, instead of generating one' do
      create(:account, :operator)
      path = Rails.root.join("tmp/platform-cert-#{SecureRandom.hex(4)}.pem").to_s

      expect do
        Rake::Task['operator:platform_cert:export'].execute(Rake::TaskArguments.new([:path], [path]))
      end.to raise_error(PlatformCertificate::MissingCertificateError, /seed/)
      expect { Rake::Task['operator:platform_cert:fingerprint'].execute }
        .to raise_error(PlatformCertificate::MissingCertificateError, /seed/)

      expect(File.exist?(path)).to be(false)
      expect(EncryptedConfig.count).to eq(0)
    ensure
      FileUtils.rm_f(path)
    end

    it 'rotates from the command line and prints both fingerprints and no key material' do
      platform_row = platform_certificate!
      old_fingerprint = PlatformCertificate.fingerprint(platform_row.value.fetch('cert'))

      output = capture_stdout { Rake::Task['operator:platform_cert:rotate'].execute }

      expect(output).to include(old_fingerprint)
      expect(output).to include(PlatformCertificate.fingerprint)
      expect(PlatformCertificate.fingerprint).not_to eq(old_fingerprint)
      expect(output).to include('operator:platform_cert:export')
      expect(output).not_to include('PRIVATE KEY')
      expect(output).not_to include('BEGIN CERTIFICATE')
      expect(EncryptedConfig.find_by!(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_RETIRED_KEY).value.size).to eq(1)
    end

    it 'prints only the fingerprint of the platform certificate' do
      platform_certificate!

      output = capture_stdout { Rake::Task['operator:platform_cert:fingerprint'].execute }

      expect(output.strip).to eq(PlatformCertificate.fingerprint)
      expect(output).to match(/\A(\h{2}:){31}\h{2}\n\z/)
    end
  end
end
