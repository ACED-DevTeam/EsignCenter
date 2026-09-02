# frozen_string_literal: true

require 'rake'

# Public /verify answers date + signer count only, never identities;
# rate-limited and size-capped; records survive purge.
#
# Anyone can POST a PDF to /verify without a login. The page answers from two
# things only: the permanent VerifiedDocument record of the exact bytes
# EsignCenter signed (hex SHA-256, day, signer count) and the PDF's own
# digital signature checked against the platform trust set. A hit on both is
# `verified` and shows the completion day and "N signers" — never the
# signer's name, email, certificate subject, signing reason or time of day.
# One file per request, 25 MB cap refused before the file is read or parsed,
# ten posts a minute per IP. The record has no foreign keys and no
# associations, so destroying the submission and then the whole account
# changes nothing on the page. A signature counts as ours only when its key
# is the platform's (current or retired), an internal or operator account's
# — never a TRUSTED_CERTS environment key — and the page never generates the
# platform certificate. See docs/verify.md.
RSpec.describe 'Public verify', type: :request do
  let!(:account) { create(:account) }
  let(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }
  let(:english) { { 'HTTP_ACCEPT_LANGUAGE' => 'en-US' } }
  let(:today) { I18n.l(Time.current.utc.to_date, format: :long, locale: :en) }

  before { RateLimit.store.clear }
  after { RateLimit.store.clear }

  def admin_for(account)
    admins[account.id] ||= create(:user, :admin, account:)
  end

  def text_template_for(account, submitter_count: 1)
    create(:template, account:, author: admin_for(account), only_field_types: %w[text], submitter_count:)
  end

  def submission_for(account, submitter_count: 1)
    template = text_template_for(account, submitter_count:)
    submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))

    submission.submitters.each_with_index do |submitter, index|
      submitter.update!(sent_at: Time.current, email: "jane.signer#{index}@example.com", name: "Jane Signer #{index}")
    end

    submission
  end

  def text_field(submitter)
    fields = submitter.submission.template_fields.presence || submitter.submission.template.fields

    fields.find { |f| f['type'] == 'text' && f['submitter_uuid'] == submitter.uuid }
  end

  # The real interactive completion path, consent included (Phase A).
  def complete!(submitter)
    put "/s/#{submitter.slug}", params: { completed: 'true', esign_consent: 'true',
                                          esign_consent_version: EsignConsent::VERSION,
                                          values: { text_field(submitter)['uuid'] => 'Jane' } }

    expect(response).to have_http_status(:ok)

    submitter.reload
  end

  # Exactly what a customer downloads for this submitter.
  def downloaded_bytes(submitter)
    attachments = Submitters.select_attachments_for_download(submitter)

    expect(attachments.size).to eq(1)

    attachments.first.download
  end

  def verify(bytes, filename: 'signed.pdf', content_type: 'application/pdf', headers: english)
    file = Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: filename)

    post '/verify', params: { file: }, headers:
  end

  def result_state
    Nokogiri::HTML(response.body).at_css('#verify_result')&.[]('data-state')
  end

  def error_class
    Nokogiri::HTML(response.body).at_css('#verify_result .verify-error')&.[]('class')
  end

  def expect_no_identities(body, submission)
    submission.submitters.each do |submitter|
      expect(body).not_to include(submitter.email)
      expect(body).not_to include(submitter.name)
    end

    expect(body).not_to include('CN=')
    expect(body).not_to include(Submissions::GenerateResultAttachments.single_sign_reason(submission.submitters.last))
    expect(body).not_to match(/\d{1,2}:\d{2}/)
  end

  def unsigned_pdf
    Rails.root.join('spec/fixtures/sample-document.pdf').binread
  end

  def signer_public_keys(bytes)
    HexaPDF::Document.new(io: StringIO.new(bytes)).signatures.map do |signature|
      signature.signature_handler.signer_certificate.public_key.to_der
    end
  end

  def public_key_of(pem)
    OpenSSL::X509::Certificate.new(pem).public_key.to_der
  end

  # The fixture signed with an identity that is not ours (its own generated
  # chain), the way any other PDF tool would sign it.
  def pdf_signed_by(pkcs)
    document = HexaPDF::Document.new(io: StringIO.new(unsigned_pdf))
    io = StringIO.new

    document.sign(io, certificate: pkcs.certificate, key: pkcs.key, certificate_chain: pkcs.ca_certs,
                      reason: 'Signed elsewhere', write_options: { validate: false })

    io.string
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  describe 'a completed document' do
    it 'verifies the downloaded PDF anonymously and reveals only the day and the signer count', sidekiq: :inline do
      platform_certificate!
      submission = submission_for(account)
      submitter = complete!(submission.submitters.first)

      sign_out(:user)
      reset!
      expect(User.exists?).to be(true)

      verify(downloaded_bytes(submitter))

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('verified')
      expect(response.body).to include(today)
      expect(response.body).to include('1 signer')
      expect(response.body).not_to include('1 signers')
      expect_no_identities(response.body, submission)
    end

    it 'counts two signers and verifies the combined and audit-trail PDFs too', sidekiq: :inline do
      platform_certificate!
      submission = submission_for(account, submitter_count: 2)
      submission.submitters.order(:id).each { |submitter| complete!(submitter) }
      last_submitter = submission.reload.submitters.order(:completed_at).last
      combined = Submissions::GenerateCombinedAttachment.call(last_submitter)

      { 'signed document' => downloaded_bytes(last_submitter),
        'combined PDF' => combined.download,
        'audit trail' => submission.reload.audit_trail.download }.each do |name, bytes|
        verify(bytes)

        expect(response).to have_http_status(:ok), name
        expect(result_state).to eq('verified'), name
        expect(response.body).to include('2 signers'), name
        expect_no_identities(response.body, submission)
      end
    end

    it 'verifies an internal account document signed with its own certificate', sidekiq: :inline do
      platform_certificate!
      create(:encrypted_config, account: internal_account, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: GenerateCertificate.call.transform_values(&:to_pem))
      submission = submission_for(internal_account)
      submitter = complete!(submission.submitters.first)

      verify(downloaded_bytes(submitter))

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('verified')
      expect(response.body).to include('1 signer')
    end
  end

  describe 'negative paths' do
    it 'reports an unsigned PDF as not verified' do
      platform_certificate!

      verify(unsigned_pdf)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('not_verified')
    end

    it 'never verifies a signed PDF that was changed after signing', sidekiq: :inline do
      platform_certificate!
      submission = submission_for(account)
      bytes = downloaded_bytes(complete!(submission.submitters.first))

      verify("#{bytes}\n")

      expect(response).to have_http_status(:ok)
      expect(result_state).not_to eq('verified')
      # HexaPDF still validates the original signed byte range, so the file is
      # recognisably ours but its bytes match no record: not_on_record, whose
      # wording says "changed since it was signed". A record for the tampered
      # bytes never exists.
      expect(result_state).to eq('not_on_record')
      expect(response.body).to include(I18n.t('verify_result_not_on_record', locale: :en))
      expect(VerifiedDocument.find_by(sha256: Digest::SHA256.hexdigest("#{bytes}\n"))).to be_nil
      expect_no_identities(response.body, submission)
    end

    it 'refuses a PNG' do
      png = Rails.root.join('spec/fixtures/sample-image.png').binread

      verify(png, filename: 'image.png', content_type: 'image/png')

      expect(response).to have_http_status(:unprocessable_content)
      expect(result_state).to eq('error')
      expect(error_class).to include('not_a_pdf')
      expect(response.body).to include(I18n.t('verify_error_not_a_pdf', locale: :en))
    end

    it 'refuses a PDF that cannot be parsed' do
      verify("%PDF-1.7\nthis is not a real pdf body\n")

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_class).to include('invalid_pdf')
    end

    it 'refuses an oversized upload with 413 before reading or parsing it' do
      allow(HexaPDF::Document).to receive(:new).and_call_original
      allow(Marcel::MimeType).to receive(:for).and_call_original

      verify("%PDF-1.7\n#{'a' * (VerifyController::MAX_FILE_SIZE + 2.megabytes)}")

      expect(response).to have_http_status(:content_too_large)
      expect(error_class).to include('file_too_large')
      expect(response.body).to include(I18n.t('verify_error_file_too_large', limit_mb: 25, locale: :en))
      expect(HexaPDF::Document).not_to have_received(:new)
      expect(Marcel::MimeType).not_to have_received(:for)
    end

    # The declared request length carries the multipart envelope on top of
    # the file: the size rule is the file's own size, so a file right at the
    # cap gets through to the PDF check instead of a 413.
    it 'lets a file exactly at the cap through the size check' do
      allow(Marcel::MimeType).to receive(:for).and_call_original

      header = "%PDF-1.7\n"
      verify(header + ('a' * (VerifyController::MAX_FILE_SIZE - header.bytesize)))

      expect(response).not_to have_http_status(:content_too_large)
      expect(Marcel::MimeType).to have_received(:for)
      expect(error_class).to include('invalid_pdf')
    end

    it 'refuses a file one byte over the cap by its own size' do
      header = "%PDF-1.7\n"
      verify(header + ('a' * (VerifyController::MAX_FILE_SIZE - header.bytesize + 1)))

      expect(response).to have_http_status(:content_too_large)
      expect(error_class).to include('file_too_large')
    end

    it 'refuses a request without a file, and one with a file list' do
      post '/verify', headers: english

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_class).to include('no_file')
      expect(response.body).to include(I18n.t('verify_error_no_file', locale: :en))

      file = Rack::Test::UploadedFile.new(StringIO.new(unsigned_pdf), 'application/pdf', original_filename: 'a.pdf')
      post '/verify', params: { file: [file, file] }, headers: english

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_class).to include('no_file')
    end

    it 'rate-limits the eleventh post in a minute from one IP with a friendly page, not a redirect' do
      platform_certificate!

      10.times do
        verify(unsigned_pdf)

        expect(response).to have_http_status(:ok)
      end

      verify(unsigned_pdf)

      expect(response).to have_http_status(:too_many_requests)
      expect(response).not_to be_redirect
      expect(error_class).to include('too_many_requests')
      expect(response.body).to include(I18n.t('verify_error_too_many_requests', locale: :en))
      expect(response.body).to include('id="verify_form"')
    end
  end

  describe 'what counts as our signature' do
    # TRUSTED_CERTS lets the chain check pass; it must never make a stranger's
    # signature an EsignCenter one.
    it 'never verifies a signature made with a TRUSTED_CERTS-only key' do
      platform_certificate!
      other = GenerateCertificate.load_pkcs(GenerateCertificate.call('Elsewhere').transform_values(&:to_pem)
                                                               .stringify_keys)
      allow(Docuseal).to receive(:trusted_certs).and_return([other.certificate, *other.ca_certs])
      bytes = pdf_signed_by(other)

      expect(signer_public_keys(bytes)).to eq([other.certificate.public_key.to_der])
      expect(Accounts.platform_verification_certs.map(&:to_pem)).to include(other.certificate.to_pem)
      expect(Accounts.platform_signer_certs.map(&:to_pem)).not_to include(other.certificate.to_pem)

      verify(bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('not_verified')
    end

    it 'still verifies our documents when one internal account row holds a corrupt PKCS#12', sidekiq: :inline do
      platform_certificate!
      create(:encrypted_config, account: internal_account, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: { 'custom' => [{ 'name' => 'Broken', 'status' => 'default',
                                                        'data' => Base64.urlsafe_encode64('not a pkcs12 at all'),
                                                        'password' => 'x' }] })
      allow(ErrorReport).to receive(:error).and_call_original
      submission = submission_for(account)
      bytes = downloaded_bytes(complete!(submission.submitters.first))

      verify(bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('verified')
      expect(ErrorReport).to have_received(:error)
        .with(instance_of(OpenSSL::PKCS12::PKCS12Error), hash_including(account_id: internal_account.id))
        .at_least(:once)
    end

    # A row written under an encryption key this deployment no longer has
    # raises lazily, when its value is read: reported and skipped like a
    # corrupt one, never a 500 on every upload.
    it 'still verifies our documents when one internal account row cannot be decrypted', sidekiq: :inline do
      platform_certificate!
      broken = create(:encrypted_config, account: internal_account, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                         value: { 'custom' => [] })
      allow_any_instance_of(EncryptedConfig).to receive(:value).and_wrap_original do |original, *args|
        raise ActiveRecord::Encryption::Errors::Decryption, 'unknown key' if original.receiver.id == broken.id

        original.call(*args)
      end
      allow(ErrorReport).to receive(:error).and_call_original
      submission = submission_for(account)
      bytes = downloaded_bytes(complete!(submission.submitters.first))

      verify(bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('verified')
      expect(ErrorReport).to have_received(:error)
        .with(instance_of(ActiveRecord::Encryption::Errors::Decryption),
              hash_including(account_id: internal_account.id))
        .at_least(:once)
    end
  end

  describe 'the page never generates the platform certificate' do
    it 'answers not verified with no platform row yet, and writes no row' do
      create(:account, :operator)

      expect(PlatformCertificate.current_row).to be_nil

      expect { verify(unsigned_pdf) }.not_to change(EncryptedConfig, :count)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('not_verified')
      expect(PlatformCertificate.current_row).to be_nil
    end

    it 'answers not verified with no operator account at all, never a 500' do
      expect(Account.exists?(account_kind: Account::OPERATOR_KIND)).to be(false)

      expect { verify(unsigned_pdf) }.not_to change(EncryptedConfig, :count)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('not_verified')
    end

    it 'keeps the API verify tool from generating it too' do
      api_account = create(:account, :paid)
      api_user = create(:user, account: api_account)

      expect do
        post '/api/tools/verify', headers: { 'x-auth-token': api_user.access_token.token },
                                  params: { file: Base64.encode64(unsigned_pdf) }.to_json
      end.not_to change(EncryptedConfig, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['checksum_status']).to eq('not_found')
    end
  end

  describe 'platform certificate rotation' do
    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('operator:platform_cert:rotate')
    end

    after { Rake::Task['operator:platform_cert:rotate'].reenable }

    it 'keeps verifying documents signed before the rotation and signs new ones with the new leaf',
       sidekiq: :inline do
      platform_certificate!
      old_pems = PlatformCertificate.current_row.value
      old_bytes = downloaded_bytes(complete!(submission_for(account).submitters.first))

      expect(signer_public_keys(old_bytes)).to eq([public_key_of(old_pems.fetch('cert'))])

      output = capture_stdout { Rake::Task['operator:platform_cert:rotate'].execute }

      new_pems = PlatformCertificate.current_row.value
      expect(new_pems.fetch('cert')).not_to eq(old_pems.fetch('cert'))
      expect(output).to include(PlatformCertificate.fingerprint(old_pems.fetch('cert')))
      expect(output).to include(PlatformCertificate.fingerprint(new_pems.fetch('cert')))
      expect(output).not_to include('PRIVATE KEY')

      expect(EncryptedConfig.where(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_KEY).count).to eq(1)
      retired = EncryptedConfig.find_by!(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_RETIRED_KEY).value
      expect(retired.size).to eq(1)
      expect(retired.sole).to include('cert' => old_pems.fetch('cert'))
      expect(retired.sole.keys).not_to include('key')

      verify(old_bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('verified')
      expect(response.body).to include(today)
      expect(response.body).to include('1 signer')

      new_bytes = downloaded_bytes(complete!(submission_for(account).submitters.first))

      expect(signer_public_keys(new_bytes)).to eq([public_key_of(new_pems.fetch('cert'))])

      verify(new_bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('verified')
    end
  end

  describe 'purge survival' do
    it 'still verifies after the submission and then the whole account are destroyed', sidekiq: :inline do
      platform_certificate!
      submission = submission_for(account)
      bytes = downloaded_bytes(complete!(submission.submitters.first))

      verify(bytes)

      expect(result_state).to eq('verified')
      record_count = VerifiedDocument.count
      record = VerifiedDocument.find_by!(sha256: Digest::SHA256.hexdigest(bytes))

      submission.destroy!
      account.destroy!

      expect(Submission.exists?(submission.id)).to be(false)
      expect(Account.exists?(account.id)).to be(false)
      expect(VerifiedDocument.count).to eq(record_count)
      expect(record.reload.attributes).to include('signers_count' => 1, 'kind' => 'document')

      verify(bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('verified')
      expect(response.body).to include(today)
      expect(response.body).to include('1 signer')
    end
  end

  describe 'the page' do
    stash_env 'REGISTRATION_ENABLED', clear: true

    it 'renders for an anonymous visitor with no users at all: never a sign-in or setup redirect' do
      expect(User.exists?).to be(false)
      expect(ENV.fetch('REGISTRATION_ENABLED', nil)).to be_nil

      get '/verify'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('verify_page_title', locale: :'en-GB'))
      expect(response.body).to include('id="verify_form"')
      expect(response.body).to include('accept="application/pdf"')
    end

    it 'no longer serves the old in-app verify route' do
      # show_exceptions is :none in the test environment, so an unmatched
      # route surfaces as the RoutingError production renders as 404.
      expect { post '/verify_pdf_signature' }.to raise_error(ActionController::RoutingError)
      expect(Rails.application.routes.url_helpers).not_to respond_to(:verify_pdf_signature_index_path)
    end
  end
end
