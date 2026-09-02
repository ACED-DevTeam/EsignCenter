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
# Stands in for a timestamp authority: answers HexaPDF's timestamp_handler
# contract (`sign(io, byte_range)` → a CMS token) with a token over the
# signature bytes, signed by `pkcs` — the shape a real RFC 3161 token has once
# it sits in the signature's unsigned attributes.
class VerifySpecTimestampAuthority
  def initialize(pkcs)
    @pkcs = pkcs
  end

  def sign(io, byte_range)
    io.pos = byte_range[0]

    HexaPDF::DigitalSignature::Signing::SignedDataCreator.create(
      io.read(byte_range[1]), type: :cms, certificate: @pkcs.certificate, key: @pkcs.key,
                              certificates: @pkcs.ca_certs
    )
  end
end

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

  # The fixture signed with an identity that is not ours (its own generated
  # chain), the way any other PDF tool would sign it.
  def pdf_signed_by(pkcs)
    document = HexaPDF::Document.new(io: StringIO.new(unsigned_pdf))
    io = StringIO.new

    document.sign(io, certificate: pkcs.certificate, key: pkcs.key, certificate_chain: pkcs.ca_certs,
                      reason: 'Signed elsewhere', write_options: { validate: false })

    io.string
  end

  # The fixture signed with `pkcs` through HexaPDF's external-signing hook,
  # with a CMS encoding that ends in a zero byte.
  def pdf_signed_with_zero_terminated_cms(pkcs, timestamp_handler: nil)
    document = HexaPDF::Document.new(io: StringIO.new(unsigned_pdf))
    io = StringIO.new

    document.sign(io, signature_size: 30_000, write_options: { validate: false },
                      external_signing: lambda { |signed_io, byte_range|
                        data = signed_io.pread(byte_range[1], byte_range[0]) +
                               signed_io.pread(byte_range[3], byte_range[2])

                        zero_terminated_cms(data, pkcs, timestamp_handler:)
                      })

    io.string
  end

  # Signing times are tried until the CMS ends in a zero byte — the last byte
  # of the RSA value (of the timestamp token's, when one is embedded: it
  # signs the signature bytes, so it changes with them), about one try in 256.
  def zero_terminated_cms(data, pkcs, timestamp_handler: nil)
    base = Time.current.to_i
    candidates = 4096.times.lazy.map do |offset|
      HexaPDF::DigitalSignature::Signing::SignedDataCreator.create(
        data, type: :cms, certificate: pkcs.certificate, key: pkcs.key, certificates: pkcs.ca_certs,
              signing_time: Time.zone.at(base + offset), timestamp_handler:
      ).to_der
    end

    candidates.find { |der| der.end_with?("\x00") } || raise('no zero-terminated CMS signature in 4096 tries')
  end

  # `bytes` with the first bytes of its signature's CMS overwritten: a
  # signature no checker can read, in a PDF that still parses (the byte range
  # and the file length are untouched).
  def with_unreadable_cms(bytes)
    bytes.sub(%r{(/Contents\s*<)\h{8}}, '\\1ffffffff')
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

  describe 'the day shown' do
    def long_date(time)
      I18n.l(time.utc.to_date, format: :long, locale: :en)
    end

    # Turning on "combine PDF result" after the fact builds the combined PDF
    # lazily at the first download — days later; the page must still name
    # the day the signing finished, never the day the file was produced.
    it 'names the completion day for a combined PDF built at download three days later', sidekiq: :inline do
      platform_certificate!
      submission = submission_for(account)
      submitter = complete!(submission.submitters.first)
      completion_day = long_date(submitter.completed_at)

      create(:account_config, account:, key: AccountConfig::COMBINE_PDF_RESULT_KEY, value: true)
      expect(submission.reload.combined_document_attachment).to be_nil

      travel 3.days do
        download_day = long_date(Time.current)
        expect(download_day).not_to eq(completion_day)

        bytes = downloaded_bytes(submitter)

        expect(submission.reload.combined_document_attachment).to be_present
        record = VerifiedDocument.find_by!(sha256: VerifiedDocuments.sha256(bytes))
        expect(record.kind).to eq('combined')
        expect(record.signed_at).to be_within(1.second).of(submitter.completed_at)

        sign_out(:user)
        reset!

        verify(bytes)

        expect(response).to have_http_status(:ok)
        expect(result_state).to eq('verified')
        expect(response.body).to include(completion_day)
        expect(response.body).not_to include(download_day)
        expect(response.body).to include('1 signer')
      end
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

    it 'rate-limits the 101st post in an hour from one IP with the same friendly page' do
      stub_const('VerifyController::MINUTE_LIMIT', 1_000)
      invalid_pdf = "%PDF-1.7\n"

      100.times { verify(invalid_pdf) }
      verify(invalid_pdf)

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

    # One signature in 256 ends its CMS encoding on a zero byte. The PDF pads
    # the signature slot with zeros too, and stock HexaPDF stripped every
    # trailing zero before decoding — that real one included — so the check
    # raised and the page called a genuine document "not verified"
    # (config/initializers/hexapdf.rb). The flake that hit three suite runs.
    it 'still counts our signature when its CMS encoding ends in a zero byte' do
      platform_certificate!
      allow(ErrorReport).to receive(:warning).and_call_original
      pkcs = PlatformCertificate.pkcs
      bytes = pdf_signed_with_zero_terminated_cms(pkcs)

      expect(signer_public_keys(bytes)).to eq([pkcs.certificate.public_key.to_der])
      expect(OpenSSL::PKCS7.new(HexaPDF::Document.new(io: StringIO.new(bytes)).signatures.first.contents).to_der)
        .to end_with("\x00")

      verify(bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('not_on_record')
      expect(ErrorReport).not_to have_received(:warning)
    end

    # The same override walks the unsigned attributes for the timestamp
    # token; a zero-terminated CMS carrying one must give the token back.
    it 'reads the embedded timestamp token of our signature when its CMS ends in a zero byte' do
      platform_certificate!
      allow(ErrorReport).to receive(:warning).and_call_original
      pkcs = PlatformCertificate.pkcs
      tsa = GenerateCertificate.load_pkcs(GenerateCertificate.call('Timestamp Authority')
                                                             .transform_values(&:to_pem).stringify_keys)
      bytes = pdf_signed_with_zero_terminated_cms(pkcs, timestamp_handler: VerifySpecTimestampAuthority.new(tsa))
      signature = HexaPDF::Document.new(io: StringIO.new(bytes)).signatures.first

      expect(OpenSSL::PKCS7.new(signature.contents).to_der).to end_with("\x00")

      token = signature.signature_handler.embedded_tsa_signature

      expect(token).to be_a(OpenSSL::PKCS7)
      expect(token.certificates.map { |c| c.subject.to_s }).to include(tsa.certificate.subject.to_s)
      expect(token.certificates.map { |c| c.subject.to_s }).not_to include(pkcs.certificate.subject.to_s)

      verify(bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('not_on_record')
      expect(ErrorReport).not_to have_received(:warning)
    end

    # An unreadable signature is reported only when it is plausibly ours: a
    # stranger's broken PDF is an anonymous upload, not a verifier bug, and
    # must not reach Sentry (100 posts an hour per IP would be 100 warnings).
    it 'refuses a stranger signature the checker cannot read silently, without a warning' do
      platform_certificate!
      allow(ErrorReport).to receive(:warning).and_call_original
      other = GenerateCertificate.load_pkcs(GenerateCertificate.call('Elsewhere').transform_values(&:to_pem)
                                                               .stringify_keys)
      bytes = with_unreadable_cms(pdf_signed_by(other))

      expect(bytes.bytesize).to eq(pdf_signed_by(other).bytesize)
      expect { HexaPDF::Document.new(io: StringIO.new(bytes)).signatures.first.signature_handler }
        .to raise_error(HexaPDF::Error, /invalid/)

      verify(bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('not_verified')
      expect(ErrorReport).not_to have_received(:warning)
    end

    # The stub is on the checker (HexaPDF's Signature#verify), not on the
    # thing under test — the controller's decision to report a failed read of
    # a signature whose key is ours. A real unreadable-but-ours signature was
    # the zero-byte CMS above, which the override now reads.
    it 'warns when a signature made with our key cannot be checked, and still refuses it' do
      platform_certificate!
      allow(ErrorReport).to receive(:warning).and_call_original
      pkcs = PlatformCertificate.pkcs
      bytes = pdf_signed_by(pkcs)

      expect(signer_public_keys(bytes)).to eq([pkcs.certificate.public_key.to_der])

      allow_any_instance_of(HexaPDF::DigitalSignature::Signature)
        .to receive(:verify).and_raise(HexaPDF::Error, 'checker bug')

      verify(bytes)

      expect(response).to have_http_status(:ok)
      expect(result_state).to eq('not_verified')
      expect(ErrorReport).to have_received(:warning)
        .with(an_instance_of(HexaPDF::Error), verify: 'signature check raised').once
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
