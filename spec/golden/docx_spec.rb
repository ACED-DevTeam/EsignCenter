# frozen_string_literal: true

# Word uploads convert to PDF in a background queue with timeout, size cap,
# isolation and a visible state; API stays PDF-only.
#
# The dashboard and the builder accept .docx/.doc, store the file as uploaded
# with a `converting` placeholder in the template schema, and hand it to
# ConvertWordDocumentJob on the low-concurrency `documents` queue. The job
# (real LibreOffice here) swaps a PDF blob into the same attachment, keeps the
# uuid, and purges the Word blob. Refusals are specific and leave nothing
# behind: no attachment, no orphan template, no job.
RSpec.describe 'Word document uploads', type: :request do
  let(:docx_type) { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }
  let(:xlsx_type) { 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }
  let(:docx_path) { Rails.root.join('spec/fixtures/fieldtags.docx') }

  before do
    RateLimit.store.clear
    WordConverter.reset!
  end

  after do
    RateLimit.store.clear
    WordConverter.reset!
  end

  def docx_upload
    fixture_file_upload(docx_path, docx_type)
  end

  def upload_to_dashboard(file = docx_upload)
    post '/templates_upload', params: { files: [file] }
  end

  def expect_refusal(message)
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(message)
    expect(Template.count).to eq(0)
    expect(ActiveStorage::Attachment.where(record_type: 'Template').count).to eq(0)
    expect(ConvertWordDocumentJob.jobs).to be_empty
  end

  describe 'dashboard upload' do
    before do
      sign_in(user)
    end

    it 'stores the Word file as a converting placeholder and queues the conversion' do
      upload_to_dashboard

      template = Template.sole
      expect(response).to redirect_to(edit_template_path(template))

      attachment = template.documents.sole
      expect(attachment.content_type).to eq(docx_type)
      expect(attachment.metadata['converting']).to be(true)
      expect(attachment.metadata['original_filename']).to eq('fieldtags.docx')
      expect(attachment.preview_images).to be_empty

      expect(template.schema).to eq([{ 'attachment_uuid' => attachment.uuid, 'name' => 'fieldtags',
                                       'converting' => true }])

      job = ConvertWordDocumentJob.jobs.sole
      expect(job['queue']).to eq('documents')
      expect(job['args']).to eq([{ 'template_id' => template.id, 'attachment_uuid' => attachment.uuid }])

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      expect(response.parsed_body).to include('status' => 'converting',
                                              'schema_item' => hash_including('converting' => true))
      expect(response.parsed_body).not_to have_key('document')
    end

    it 'converts the document with LibreOffice, swaps the PDF in and purges the Word blob' do
      upload_to_dashboard

      template = Template.sole
      attachment = template.documents.sole
      word_blob_id = attachment.blob_id

      ConvertWordDocumentJob.drain
      Sidekiq::Worker.drain_all

      attachment.reload
      expect(attachment.blob_id).not_to eq(word_blob_id)
      expect(attachment.content_type).to eq('application/pdf')
      expect(attachment.filename.to_s).to eq('fieldtags.pdf')
      expect(attachment.metadata['converting']).to be_nil
      expect(attachment.metadata.dig('pdf', 'number_of_pages')).to be >= 1
      expect(attachment.metadata['sha256']).to be_present
      expect(attachment.preview_images.count).to be >= 1
      expect(attachment.download).to start_with('%PDF')

      expect(ActiveStorage::Blob.exists?(word_blob_id)).to be(false)

      template.reload
      expect(template.schema.sole).not_to have_key('converting')
      expect(template.schema.sole['attachment_uuid']).to eq(attachment.uuid)

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      body = response.parsed_body
      expect(body['status']).to eq('ready')
      expect(body['schema_item']).to eq(template.schema.sole)
      expect(body['document']).to include('uuid' => attachment.uuid, 'signed_key' => be_present)
      expect(body['document']['metadata'].dig('pdf', 'number_of_pages'))
        .to eq(attachment.metadata.dig('pdf', 'number_of_pages'))
      expect(body['document']['preview_images']).to all(include('url', 'metadata', 'filename'))
    end

    it 'refuses a spreadsheet with a specific message and leaves no orphan template' do
      upload_to_dashboard(Rack::Test::UploadedFile.new(StringIO.new('not a spreadsheet'), xlsx_type,
                                                       original_filename: 'sheet.xlsx'))

      expect_refusal(I18n.t('unsupported_document_format'))
    end

    it 'refuses a Word file above the size cap before queueing anything' do
      big = Rack::Test::UploadedFile.new(StringIO.new('x' * (WordConverter::MAX_FILE_SIZE + 1.megabyte)), docx_type,
                                         original_filename: 'big.docx')

      upload_to_dashboard(big)

      expect_refusal(I18n.t('word_file_too_large', limit_mb: 20))
      expect(flash[:alert]).to include('20 MB')
    end

    context 'with the kill switch on' do
      stash_env 'WORD_CONVERSION_ENABLED'

      before do
        ENV['WORD_CONVERSION_ENABLED'] = 'false'
      end

      it 'refuses Word files and stops offering them in the upload form' do
        upload_to_dashboard

        expect_refusal(I18n.t('word_conversion_unavailable'))

        get root_path

        expect(response.body).to include('accept="image/*, application/pdf, application/zip, application/json"')
        expect(response.body).not_to include('.docx')
      end
    end

    it 'marks the document failed and reports once when LibreOffice cannot convert it' do
      allow(WordConverter).to receive(:call).and_raise(WordConverter::ConversionError, 'soffice exited with 1')
      allow(ErrorReport).to receive(:warning).and_call_original

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole

      ConvertWordDocumentJob.drain

      attachment.reload
      expect(attachment.metadata['converting']).to be_nil
      expect(attachment.metadata['conversion_failed']).to be(true)
      expect(attachment.content_type).to eq(docx_type)

      template.reload
      expect(template.schema.sole).to include('conversion_failed' => true)
      expect(template.schema.sole).not_to have_key('converting')

      expect(ErrorReport).to have_received(:warning)
        .with(instance_of(WordConverter::ConversionError), template_id: template.id, attachment_uuid: attachment.uuid)
        .once
      expect(ConvertWordDocumentJob.jobs).to be_empty

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      expect(response.parsed_body).to include('status' => 'failed',
                                              'schema_item' => hash_including('conversion_failed' => true))
    end

    it 'refuses the 31st conversion of the hour for one account' do
      30.times { RateLimit.call("word-conversion-#{account.id}", limit: 30, ttl: 1.hour) }

      upload_to_dashboard

      expect_refusal(I18n.t('too_many_word_conversions'))
    end
  end

  describe 'the conversion job under a full slot counter' do
    before do
      sign_in(user)
    end

    it 're-enqueues itself with a delay and converts nothing' do
      allow(WordConverter).to receive(:call).and_call_original

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      job_args = ConvertWordDocumentJob.jobs.sole['args'].first
      ConvertWordDocumentJob.jobs.clear

      WordConverter::MAX_CONCURRENT.times { RateLimit.store.increment(WordConverter::ACTIVE_KEY, 1) }

      ConvertWordDocumentJob.new.perform(job_args)

      expect(WordConverter).not_to have_received(:call)
      expect(attachment.reload.metadata['converting']).to be(true)
      expect(RateLimit.store.read(WordConverter::ACTIVE_KEY)).to eq(WordConverter::MAX_CONCURRENT)

      retry_job = ConvertWordDocumentJob.jobs.sole
      expect(retry_job['at']).to be_within(30).of(15.seconds.from_now.to_f)
      expect(retry_job['args']).to eq([job_args.merge('busy_retries' => 1)])
    end
  end

  describe 'builder add-document' do
    let(:template) { create(:template, account:, author: user) }

    before do
      sign_in(user)
    end

    it 'accepts a Word file and returns the converting placeholder in the add-document shape' do
      post "/templates/#{template.id}/documents", params: { files: [docx_upload] }

      expect(response).to have_http_status(:ok)

      attachment = template.documents.find_by!(uuid: response.parsed_body['schema'].sole['attachment_uuid'])
      expect(response.parsed_body['schema'].sole).to eq('attachment_uuid' => attachment.uuid, 'name' => 'fieldtags',
                                                        'converting' => true)
      expect(response.parsed_body['documents'].sole).to include('uuid' => attachment.uuid,
                                                                'metadata' => hash_including('converting' => true))
      expect(ConvertWordDocumentJob.jobs.sole['queue']).to eq('documents')
    end

    it 'refuses a spreadsheet with the same specific message as JSON' do
      expect do
        post "/templates/#{template.id}/documents", params: {
          files: [Rack::Test::UploadedFile.new(StringIO.new('not a spreadsheet'), xlsx_type,
                                               original_filename: 'sheet.xlsx')]
        }
      end.not_to(change { template.documents.count })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => I18n.t('unsupported_document_format'))
    end
  end

  # No browser session here: the API is a paid feature and the refusal under
  # test is the format check behind that door, so the caller is an entitled
  # token holder and nothing else.
  describe 'API' do
    let!(:api_user) { create(:user, account: create(:account, :internal)) }

    it 'keeps refusing Word documents with 422 and creates nothing' do
      docx_base64 = Base64.encode64(docx_path.read)

      expect do
        post '/api/templates', headers: { 'x-auth-token': api_user.access_token.token }, params: {
          documents: [{ name: 'contract.docx', file: docx_base64 }]
        }.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error'])
        .to eq('Unsupported document format. Only PDF and image files are supported.')
      expect(ConvertWordDocumentJob.jobs).to be_empty
    end
  end

  # A converting (or failed) Word document means there is no PDF to sign yet,
  # so nothing may start a signing from the template until the job is done.
  describe 'sending while a Word document is not ready' do
    let!(:account) { create(:account, :internal) }
    let(:api_headers) { { 'x-auth-token': user.access_token.token, 'CONTENT_TYPE' => 'application/json' } }
    let(:converting_message) { I18n.t('documents_still_converting') }
    let(:failed_message) { I18n.t('document_conversion_failed') }

    let(:template) { Template.sole }

    before do
      sign_in(user)
      upload_to_dashboard
    end

    def post_api_submission
      post '/api/submissions', headers: api_headers, params: {
        template_id: template.id, submitters: [{ email: 'signer@example.com' }]
      }.to_json
    end

    it 'refuses the UI send dialog with the alert and creates no submission' do
      post "/templates/#{template.id}/submissions", params: { emails: 'signer@example.com', send_email: '1' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(converting_message)
      expect(Submission.count).to eq(0)
      expect(Submitter.count).to eq(0)
    end

    it 'refuses the API with 422 and the message, then accepts once the job has run' do
      post_api_submission

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => converting_message)
      expect(Submission.count).to eq(0)

      ConvertWordDocumentJob.drain

      # The converted document carries no form fields of its own; a template
      # needs at least one before the API sends it, as for any PDF.
      template.reload
      if template.fields.blank?
        template.update!(fields: [{ 'uuid' => SecureRandom.uuid, 'name' => 'Signature', 'type' => 'signature',
                                    'submitter_uuid' => template.submitters.first['uuid'], 'required' => true,
                                    'areas' => [{ 'attachment_uuid' => template.schema.sole['attachment_uuid'],
                                                  'page' => 0, 'x' => 0.1, 'y' => 0.1, 'w' => 0.3, 'h' => 0.05 }] }])
      end

      expect { post_api_submission }.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)
    end

    it 'shows the not-ready page on the shared link and creates no submitter' do
      template.update!(shared_link: true)

      get "/d/#{template.slug}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(converting_message)
      expect(response.body).to include(I18n.t('document_not_ready'))

      put "/d/#{template.slug}", params: { submitter: { email: 'signer@example.com' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Submitter.count).to eq(0)
      expect(Submission.count).to eq(0)
    end

    it 'names the failed state once the conversion has failed' do
      allow(WordConverter).to receive(:call).and_raise(WordConverter::ConversionError, 'boom')

      ConvertWordDocumentJob.drain

      post_api_submission

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => failed_message)
      expect(Submission.count).to eq(0)

      post "/templates/#{template.id}/submissions", params: { emails: 'signer@example.com', send_email: '1' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(failed_message)
    end
  end

  describe 'Docuseal.advanced_formats?' do
    stash_env 'WORD_CONVERSION_ENABLED', clear: true

    it 'follows the converter: on with soffice available, off under the kill switch' do
      expect(Docuseal.advanced_formats?).to be(true)

      ENV['WORD_CONVERSION_ENABLED'] = 'false'

      expect(Docuseal.advanced_formats?).to be(false)
    end
  end
end
