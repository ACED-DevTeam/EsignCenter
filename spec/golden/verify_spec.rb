# frozen_string_literal: true

# Public /verify answers date + signer count only, never identities;
# rate-limited and size-capped; records survive purge.
#
# Anyone can POST a PDF to /verify without a login. The page answers from two
# things only: the permanent VerifiedDocument record of the exact bytes
# EsignCenter signed (hex SHA-256, day, signer count) and the PDF's own
# digital signature checked against the platform trust set. A hit on both is
# `verified` and shows the completion day and "N signers" — never the
# signer's name, email, certificate subject, signing reason or time of day.
# One file per request, 25 MB cap refused before parsing, ten posts a minute
# per IP. The record has no foreign keys and no associations, so destroying
# the submission and then the whole account changes nothing on the page.
# See docs/verify.md.
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

    it 'refuses an oversized upload with 413 before parsing it' do
      allow(HexaPDF::Document).to receive(:new).and_call_original
      allow(Marcel::MimeType).to receive(:for).and_call_original

      verify("%PDF-1.7\n#{'a' * (VerifyController::MAX_FILE_SIZE + 1.megabyte)}")

      expect(response).to have_http_status(:content_too_large)
      expect(error_class).to include('file_too_large')
      expect(response.body).to include(I18n.t('verify_error_file_too_large', limit_mb: 25, locale: :en))
      expect(HexaPDF::Document).not_to have_received(:new)
      expect(Marcel::MimeType).not_to have_received(:for)
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
