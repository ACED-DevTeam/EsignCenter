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

  # fieldtags.docx converts to a PDF without an AcroForm (LibreOffice writes
  # its text tags as plain text), so field detection is stubbed at its
  # narrowest seam — Templates::FindAcroFields — and everything downstream
  # (ProcessDocument storing them, the job's marker, the status payload) runs
  # for real.
  def stub_found_fields
    allow(Templates::FindAcroFields).to receive(:call) do |_pdf, attachment, _data|
      [{ 'uuid' => SecureRandom.uuid, 'name' => 'Full name', 'type' => 'text', 'required' => true,
         'areas' => [{ 'attachment_uuid' => attachment.uuid, 'page' => 0,
                       'x' => 0.1, 'y' => 0.1, 'w' => 0.3, 'h' => 0.05 }] }]
    end
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
      fields_before = template.fields.deep_dup

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
      # The job never rewrites template.fields (an open builder would overwrite
      # it): fields it found stay in the document's metadata for the builder.
      expect(template.fields).to eq(fields_before)

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      body = response.parsed_body
      expect(body['status']).to eq('ready')
      expect(body['schema_item']).to eq(template.schema.sole)
      expect(body).not_to have_key('fields')
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

    it 'refuses a batch with an unsupported file after a good one and leaves no template behind' do
      pdf = fixture_file_upload(Rails.root.join('spec/fixtures/sample-document.pdf'), 'application/pdf')
      xlsx = Rack::Test::UploadedFile.new(StringIO.new('not a spreadsheet'), xlsx_type,
                                          original_filename: 'sheet.xlsx')

      post '/templates_upload', params: { files: [pdf, xlsx] }

      expect_refusal(I18n.t('unsupported_document_format'))
    end

    it 'routes a Word file by its bytes, whatever the browser declared or the name says' do
      upload_to_dashboard(Rack::Test::UploadedFile.new(docx_path, 'application/zip'))

      attachment = Template.sole.documents.sole
      expect(attachment.content_type).to eq(docx_type)
      expect(attachment.metadata['converting']).to be(true)
      expect(ConvertWordDocumentJob.jobs.size).to eq(1)

      Template.sole.destroy!
      ConvertWordDocumentJob.jobs.clear

      upload_to_dashboard(Rack::Test::UploadedFile.new(docx_path, 'application/pdf', original_filename: 'contract.pdf'))

      attachment = Template.sole.documents.sole
      expect(attachment.content_type).to eq(docx_type)
      expect(attachment.filename.to_s).to eq('contract.pdf')
      expect(attachment.metadata['converting']).to be(true)
      expect(ConvertWordDocumentJob.jobs.size).to eq(1)
    end

    it 'still unpacks a real zip archive into the documents inside it' do
      zip = Tempfile.new(['docs', '.zip'])
      zip.binmode
      zip.write(Zip::OutputStream.write_buffer do |out|
        out.put_next_entry('sample-document.pdf')
        out.write(Rails.root.join('spec/fixtures/sample-document.pdf').binread)
      end.string)
      zip.rewind

      upload_to_dashboard(Rack::Test::UploadedFile.new(zip.path, 'application/zip'))

      expect(Template.sole.documents.sole.content_type).to eq('application/pdf')
      expect(ConvertWordDocumentJob.jobs).to be_empty
    ensure
      zip&.close!
    end

    it 'resumes after a transient failure past the blob swap without converting again' do
      allow(WordConverter).to receive(:call).and_call_original

      calls = 0
      allow(Templates::CreateAttachments).to receive(:process_pdf_attachment)
        .and_wrap_original do |original, *args, **kwargs|
        calls += 1

        raise ActiveRecord::ConnectionTimeoutError, 'storage hiccup' if calls == 1

        original.call(*args, **kwargs)
      end

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      word_blob_id = attachment.blob_id
      job_args = ConvertWordDocumentJob.jobs.sole['args'].first

      expect { ConvertWordDocumentJob.new.perform(job_args) }.to raise_error(/storage hiccup/)

      # Half-way state: the PDF is stored, the document still counts as
      # converting, and the Word blob is still there.
      attachment.reload
      expect(attachment.content_type).to eq('application/pdf')
      expect(attachment.metadata).to include('converting' => true, 'conversion_stage' => 'pdf_stored')
      expect(Templates.documents_status(template)).to eq('converting')
      expect(ActiveStorage::Blob.exists?(word_blob_id)).to be(true)

      ConvertWordDocumentJob.new.perform(job_args)
      Sidekiq::Worker.drain_all

      expect(WordConverter).to have_received(:call).once

      attachment.reload
      expect(attachment.metadata['converting']).to be_nil
      expect(attachment.metadata['conversion_stage']).to be_nil
      expect(attachment.metadata.dig('pdf', 'number_of_pages')).to be >= 1
      expect(attachment.preview_images.count).to be >= 1
      expect(Templates.documents_status(template.reload)).to be_nil
      expect(template.schema.sole).not_to have_key('converting')
      expect(ActiveStorage::Blob.exists?(word_blob_id)).to be(false)
    end

    # The job never writes template.fields (an open builder would overwrite
    # it): the fields it found ride in the document's metadata and the schema
    # item carries `pending_fields`, so the builder merges them from the poll
    # or on its next mount.
    it 'hands the fields it found to the builder through the status payload and a pending_fields marker' do
      stub_found_fields

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      fields_before = template.fields.deep_dup

      ConvertWordDocumentJob.drain
      Sidekiq::Worker.drain_all

      template.reload
      expect(template.fields).to eq(fields_before)
      expect(template.schema.sole).to include('pending_fields' => true)
      expect(template.schema.sole).not_to have_key('converting')

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      body = response.parsed_body
      expect(body['status']).to eq('ready')
      expect(body['schema_item']).to include('pending_fields' => true)
      fields = body.dig('document', 'metadata', 'pdf', 'fields')
      expect(fields).to be_present
      expect(fields.sole).to include('name' => 'Full name', 'type' => 'text')
      expect(fields.sole['areas'].sole).to include('attachment_uuid' => attachment.uuid, 'page' => 0)
    end

    it 'resumes after a failure inside the schema update without converting again and still purges the Word blob' do
      allow(WordConverter).to receive(:call).and_call_original

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      word_blob_id = attachment.blob_id
      job_args = ConvertWordDocumentJob.jobs.sole['args'].first

      job = ConvertWordDocumentJob.new
      calls = 0
      allow(job).to receive(:update_schema_item).and_wrap_original do |original, *args, &block|
        calls += 1

        raise ActiveRecord::ConnectionTimeoutError, 'database hiccup' if calls == 1

        original.call(*args, &block)
      end

      expect { job.perform(job_args) }.to raise_error(/database hiccup/)

      # The PDF is stored, the markers are still on, the Word blob is still
      # there: a retry has everything it needs and nothing is lost.
      attachment.reload
      expect(attachment.content_type).to eq('application/pdf')
      expect(attachment.metadata).to include('converting' => true, 'conversion_stage' => 'pdf_stored')
      expect(Templates.documents_status(template.reload)).to eq('converting')
      expect(template.schema.sole).to include('converting' => true)
      expect(ActiveStorage::Blob.exists?(word_blob_id)).to be(true)

      ConvertWordDocumentJob.new.perform(job_args)
      Sidekiq::Worker.drain_all

      expect(WordConverter).to have_received(:call).once

      attachment.reload
      expect(attachment.metadata['converting']).to be_nil
      expect(attachment.metadata['conversion_stage']).to be_nil
      expect(attachment.metadata['word_blob_id']).to be_nil
      expect(Templates.documents_status(template.reload)).to be_nil
      expect(template.schema.sole).not_to have_key('converting')
      expect(ActiveStorage::Blob.exists?(word_blob_id)).to be(false)
    end

    # The markers come off in the job's very last statement: a raise inside
    # that final save leaves the PDF stored, the schema already updated and
    # the markers on, so the retry resumes without LibreOffice.
    it 'resumes after a failure inside the final marker-clearing save without converting again' do
      allow(WordConverter).to receive(:call).and_call_original

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      word_blob_id = attachment.blob_id
      job_args = ConvertWordDocumentJob.jobs.sole['args'].first

      job = ConvertWordDocumentJob.new
      calls = 0
      allow(job).to receive(:clear_conversion_markers!).and_wrap_original do |original, document|
        calls += 1

        if calls == 1
          allow(document).to receive(:save!).and_raise(ActiveRecord::ConnectionTimeoutError, 'database hiccup')
        end

        original.call(document)
      end

      expect { job.perform(job_args) }.to raise_error(/database hiccup/)

      # Everything but the markers is done; the markers say "still owed".
      attachment.reload
      expect(attachment.content_type).to eq('application/pdf')
      expect(attachment.metadata).to include('converting' => true, 'conversion_stage' => 'pdf_stored',
                                             'word_blob_id' => word_blob_id)
      expect(attachment.metadata['conversion_started_at']).to be_present
      expect(Templates.documents_status(template.reload)).to eq('converting')
      expect(template.schema.sole).not_to have_key('converting')

      ConvertWordDocumentJob.new.perform(job_args)
      Sidekiq::Worker.drain_all

      expect(WordConverter).to have_received(:call).once

      attachment.reload
      expect(attachment.metadata.keys).not_to include('converting', 'conversion_stage', 'conversion_started_at',
                                                      'word_blob_id')
      expect(attachment.metadata.dig('pdf', 'number_of_pages')).to be >= 1
      expect(Templates.documents_status(template.reload)).to be_nil
      expect(template.schema.sole).not_to have_key('converting')
      expect(ActiveStorage::Blob.exists?(word_blob_id)).to be(false)
    end

    # A builder that was open when the job finished (polling timed out, or a
    # second tab) autosaves a schema copy without the marker: the fields it
    # has not merged yet must not be lost. The marker goes once a field
    # claims the document (the builder merged them) or the builder says
    # "remove" explicitly.
    it 'keeps the pending_fields marker through an autosave that did not send it, until a field claims the document' do
      stub_found_fields

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      ConvertWordDocumentJob.drain

      expect(template.reload.schema.sole).to include('pending_fields' => true)

      schema_item = { attachment_uuid: attachment.uuid, name: 'fieldtags' }

      put "/templates/#{template.id}", as: :json, params: { template: { schema: [schema_item] } }

      expect(response).to have_http_status(:ok)
      expect(template.reload.schema.sole).to include('pending_fields' => true)
      expect(template.fields).to be_blank

      # "Remove": the builder says so explicitly.
      put "/templates/#{template.id}", as: :json,
                                       params: { template: { schema: [schema_item.merge(pending_fields: false)] } }

      expect(response).to have_http_status(:ok)
      expect(template.reload.schema.sole).not_to have_key('pending_fields')

      # "Keep": the merged field claims the document, so the marker goes
      # even when the builder's copy still carries it.
      template.update!(schema: [schema_item.merge(pending_fields: true).stringify_keys])
      field = { uuid: SecureRandom.uuid, name: 'Full name', type: 'text', required: true,
                submitter_uuid: template.submitters.first['uuid'],
                areas: [{ attachment_uuid: attachment.uuid, page: 0, x: 0.1, y: 0.1, w: 0.3, h: 0.05 }] }

      put "/templates/#{template.id}", as: :json,
                                       params: { template: { schema: [schema_item.merge(pending_fields: true)],
                                                             fields: [field] } }

      expect(response).to have_http_status(:ok)
      expect(template.reload.schema.sole).not_to have_key('pending_fields')
      expect(template.fields.sole['name']).to eq('Full name')
    end

    # After "Keep" the builder's copy of the schema item may still say
    # `pending_fields: true` on every autosave. When the user then deletes
    # the merged fields, that stale `true` must count for nothing: only the
    # job arms the marker, so the deleted fields stay deleted on the next
    # mount instead of being merged again with a fresh keep-or-remove prompt.
    it 'never lets a client-sent pending_fields: true re-arm the marker once the merged fields are deleted' do
      stub_found_fields

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      ConvertWordDocumentJob.drain

      expect(template.reload.schema.sole).to include('pending_fields' => true)

      schema_item = { attachment_uuid: attachment.uuid, name: 'fieldtags', pending_fields: true }
      field = { uuid: SecureRandom.uuid, name: 'Full name', type: 'text', required: true,
                submitter_uuid: template.submitters.first['uuid'],
                areas: [{ attachment_uuid: attachment.uuid, page: 0, x: 0.1, y: 0.1, w: 0.3, h: 0.05 }] }

      # "Keep": the merged field claims the document, the marker goes.
      put "/templates/#{template.id}", as: :json, params: { template: { schema: [schema_item], fields: [field] } }

      expect(response).to have_http_status(:ok)
      expect(template.reload.schema.sole).not_to have_key('pending_fields')

      # The user deletes the merged field; the builder still sends `true`.
      put "/templates/#{template.id}", as: :json, params: { template: { schema: [schema_item], fields: [] } }

      expect(response).to have_http_status(:ok)
      expect(template.reload.schema.sole).to eq('attachment_uuid' => attachment.uuid, 'name' => 'fieldtags')
      expect(template.fields).to be_blank
      # The found fields are still in the document's metadata: only the
      # marker keeps a later mount from merging them, and it is gone.
      expect(attachment.reload.metadata.dig('pdf', 'fields')).to be_present

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      expect(response.parsed_body['schema_item']).not_to have_key('pending_fields')
    end

    it 'marks the document failed when Sidekiq gives up retrying a transient error' do
      allow(ErrorReport).to receive(:warning).and_call_original

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      job = ConvertWordDocumentJob.jobs.sole
      error = ActiveRecord::ConnectionTimeoutError.new('storage down for good')

      ConvertWordDocumentJob.sidekiq_retries_exhausted_block.call(job, error)

      attachment.reload
      expect(attachment.metadata['converting']).to be_nil
      expect(attachment.metadata['conversion_failed']).to be(true)
      expect(template.reload.schema.sole).to include('conversion_failed' => true)
      expect(template.schema.sole).not_to have_key('converting')
      expect(Templates.documents_status(template)).to eq('failed')
      expect(ErrorReport).to have_received(:warning)
        .with(error, template_id: template.id, attachment_uuid: attachment.uuid).once

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      expect(response.parsed_body).to include('status' => 'failed',
                                              'schema_item' => hash_including('conversion_failed' => true))
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

  # The 20 MB cap must hold before the upload is read into memory whole: a
  # multipart file is measured on disk first, a URL download is cut off at
  # the cap while it streams.
  describe 'the size cap before the file is read' do
    let(:template) { create(:template, account:, author: user) }

    before do
      sign_in(user)
    end

    it 'refuses an oversized multipart Word upload from its size alone, without reading it' do
      tempfile = Tempfile.new(['big', '.docx'])
      tempfile.binmode
      tempfile.truncate(WordConverter::MAX_FILE_SIZE + 1)

      file = ActionDispatch::Http::UploadedFile.new(tempfile:, filename: 'big.docx', type: docx_type)
      allow(file).to receive(:read).and_call_original
      documents_before = template.documents.count

      expect { Templates::CreateAttachments.call(template, { files: [file] }) }
        .to raise_error(WordConverter::FileTooLarge)

      expect(file).not_to have_received(:read)
      expect(template.documents.count).to eq(documents_before)
      expect(ConvertWordDocumentJob.jobs).to be_empty
    ensure
      tempfile&.close!
    end

    it 'cuts off an oversized Word download from a URL at the cap and refuses it' do
      url = 'https://files.example.com/big.docx'
      stub_request(:get, url).to_return(body: 'x' * (WordConverter::MAX_FILE_SIZE + 1.megabyte),
                                        headers: { 'Content-Type' => docx_type })

      post '/templates_upload', params: { url: }

      expect_refusal(I18n.t('word_file_too_large', limit_mb: 20))
    end
  end

  describe 'the conversion job with every slot taken' do
    before do
      sign_in(user)
    end

    it 're-enqueues itself with a delay, converts nothing and touches nobody else slot' do
      allow(WordConverter).to receive(:call).and_call_original

      upload_to_dashboard
      template = Template.sole
      attachment = template.documents.sole
      job_args = ConvertWordDocumentJob.jobs.sole['args'].first
      ConvertWordDocumentJob.jobs.clear

      WordConverter.slot_keys.each do |key|
        RateLimit.store.write(key, 'another-worker', unless_exist: true, expires_in: 10.minutes)
      end

      ConvertWordDocumentJob.new.perform(job_args)

      expect(WordConverter).not_to have_received(:call)
      expect(attachment.reload.metadata['converting']).to be(true)
      expect(WordConverter.slot_keys.map { |key| RateLimit.store.read(key) }).to all(eq('another-worker'))

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

    it 'MCP create_template refuses a Word URL with the same message and creates nothing' do
      docx_url = 'https://files.example.com/contract.docx'
      stub_request(:get, docx_url).to_return(body: docx_path.binread, headers: { 'Content-Type' => docx_type })

      mcp_token = api_user.mcp_tokens.create!(name: 'Golden')
      create(:account_config, account: api_user.account, key: AccountConfig::ENABLE_MCP_KEY, value: true)

      call = { name: 'create_template', arguments: { name: 'Word via MCP', url: docx_url } }

      expect do
        post '/mcp', headers: { 'Authorization' => "Bearer #{mcp_token.token}", 'Content-Type' => 'application/json' },
                     params: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: call }.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:ok)

      result = response.parsed_body['result']
      expect(result['isError']).to be(true)
      expect(result['content'].sole['text'])
        .to eq('Unsupported document format. Only PDF and image files are supported.')
      expect(ActiveStorage::Attachment.where(record_type: 'Template').count).to eq(0)
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
    # What the builder autosaves for the document: never the flags.
    let(:schema_item_without_flags) { { attachment_uuid: template.documents.sole.uuid, name: 'fieldtags' } }

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

    # A job that never ran (lost with the container, dead-set) must not hold
    # the template forever: half an hour after the file was stored the
    # document counts as failed, with the failed message and the Remove card.
    it 'treats a conversion still running 30 minutes after its file was stored as failed' do
      attachment = template.documents.sole

      expect(Templates.documents_status(template)).to eq('converting')

      attachment.blob.update_columns(created_at: (Templates::CONVERSION_STALE_AFTER + 1.minute).ago)

      expect(Templates.documents_status(template.reload)).to eq('failed')

      post_api_submission

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => failed_message)

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      expect(response.parsed_body).to include('status' => 'failed',
                                              'schema_item' => hash_including('conversion_failed' => true))
      expect(response.parsed_body['schema_item']).not_to have_key('converting')

      put "/templates/#{template.id}", as: :json, params: { template: { schema: [schema_item_without_flags] } }

      expect(template.reload.schema.sole).to include('conversion_failed' => true)
      expect(template.schema.sole).not_to have_key('converting')

      put "/templates/#{template.id}", params: { template: { schema: [] } }, as: :json

      expect(Templates.documents_status(template.reload)).to be_nil
    end

    # The builder autosaves the whole schema without the flags (they are not
    # its to send): readiness comes from the stored document, and the saved
    # schema gets the flag back so a reload shows the card and polls again.
    it 'keeps refusing after a builder save drops the flag, and the reloaded builder still shows the card' do
      put "/templates/#{template.id}", as: :json, params: { template: { schema: [schema_item_without_flags] } }

      expect(response).to have_http_status(:ok)
      expect(template.reload.schema.sole).to include('converting' => true)

      post_api_submission

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => converting_message)

      get "/templates/#{template.id}/edit"

      expect(response.body).to include('&quot;converting&quot;:true')
    end

    it 'names the failed state after a builder save drops the flag, until the document is removed' do
      allow(WordConverter).to receive(:call).and_raise(WordConverter::ConversionError, 'boom')
      ConvertWordDocumentJob.drain

      put "/templates/#{template.id}", as: :json, params: { template: { schema: [schema_item_without_flags] } }

      expect(response).to have_http_status(:ok)
      expect(template.reload.schema.sole).to include('conversion_failed' => true)
      expect(template.schema.sole).not_to have_key('converting')

      post_api_submission

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => failed_message)

      get "/templates/#{template.id}/edit"

      expect(response.body).to include('&quot;conversion_failed&quot;:true')

      # The card's Remove button drops the document from the schema; a failed
      # document that is no longer part of the template blocks nothing.
      put "/templates/#{template.id}", params: { template: { schema: [] } }, as: :json

      expect(Templates.documents_status(template.reload)).to be_nil
    end

    # The stamp is only ever written by the job, but a corrupt one must not
    # turn every readiness check into a 500 and defeat the stale rule: the
    # blob timestamp decides instead, and the problem is reported.
    it 'falls back to the blob timestamp when the started-at stamp cannot be parsed' do
      allow(ErrorReport).to receive(:warning).and_call_original

      # An out-of-range date: junk parses to nil, this one raises.
      expect { Time.zone.parse('2026-99-99') }.to raise_error(ArgumentError)

      attachment = template.documents.sole
      attachment.metadata['conversion_started_at'] = '2026-99-99'
      attachment.save!

      expect(Templates.documents_status(template.reload)).to eq('converting')
      expect(ErrorReport).to have_received(:warning)
        .with(an_instance_of(ArgumentError), hash_including(attachment_uuid: attachment.uuid)).at_least(:once)

      post_api_submission

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => converting_message)

      attachment.blob.update_columns(created_at: (Templates::CONVERSION_STALE_AFTER + 1.minute).ago)

      expect(Templates.documents_status(template.reload)).to eq('failed')

      get "/templates/#{template.id}/documents/#{attachment.uuid}/status"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('status' => 'failed')
    end

    it 'refuses to clone the template from the dashboard and the API while converting' do
      expect do
        post "/templates/#{template.id}/clone", params: { template: { name: 'Copy' } }
      end.not_to change(Template, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(converting_message)

      expect do
        post "/api/templates/#{template.id}/clone", headers: api_headers, params: {}.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => converting_message)
    end
  end

  # The timed-out card's Remove button only drops the document from the
  # schema: the attachment and its queued job stay behind, and neither may
  # keep blocking the template. A document the builder has just added is
  # listed client-side and saved on the next autosave, so a brand new
  # unlisted one still counts (Templates::CONVERSION_UNLISTED_GRACE).
  # Two Resubmit surfaces start a fresh submission from a completed one: the
  # dashboard button (SubmittersResubmitController) and the signer's own
  # button on the completed page (PUT /resubmit_form, anonymous, admitted on
  # a private template by the completed submitter's slug). Both are refused
  # while a Word document the template lists is converting.
  describe 'resubmitting while a Word document is not ready' do
    let!(:account) { create(:account, :internal) }
    let(:template) { create(:template, account:, author: user, only_field_types: %w[text]) }
    let(:original) do
      submission = create(:submission, :with_submitters, template:, created_by_user: user)

      submission.submitters.first.tap do |submitter|
        submitter.update!(email: user.email, sent_at: 1.hour.ago, completed_at: Time.current)
      end
    end

    before do
      sign_in(user)
      original

      pdf_item = template.schema.sole.deep_dup

      post "/templates/#{template.id}/documents", params: { files: [docx_upload] }
      put "/templates/#{template.id}", as: :json,
                                       params: { template: { schema: [pdf_item, *response.parsed_body['schema']] } }
    end

    it 'refuses the signer-side Resubmit button with the not-ready page and creates nothing' do
      expect(Templates.documents_status(template.reload)).to eq('converting')

      sign_out(:user)
      reset!

      expect do
        put '/resubmit_form', params: { resubmit: original.slug }
      end.not_to(change { [Submission.count, Submitter.count] })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('document_not_ready'))
      expect(response.body).to include(I18n.t('documents_still_converting'))
      expect(response.body).to include(template.name)
    end

    it 'refuses the dashboard Resubmit with the alert and creates nothing' do
      expect(Templates.documents_status(template.reload)).to eq('converting')

      expect do
        put "/submitters_resubmit/#{original.id}"
      end.not_to(change { [Submission.count, Submitter.count] })

      expect(response).to redirect_to("/s/#{original.slug}")
      expect(flash[:alert]).to eq(I18n.t('documents_still_converting'))
    end
  end

  # The dashboard's recipients form, the MCP send_documents tool and embedded
  # signing sessions all funnel through Submissions::CreateFromSubmitters,
  # whose readiness assert is their only guard (the send dialog and
  # POST /api/submissions carry their own, exercised above).
  describe 'the readiness guard shared by every other sender path' do
    let!(:account) { create(:account, :internal) }
    let(:template) { create(:template, account:, author: user, only_field_types: %w[text]) }
    let(:role) { template.submitters.first['name'] }
    let(:converting_message) { I18n.t('documents_still_converting') }
    let(:json_headers) { { 'CONTENT_TYPE' => 'application/json' } }

    before do
      sign_in(user)

      pdf_item = template.schema.sole.deep_dup

      post "/templates/#{template.id}/documents", params: { files: [docx_upload] }
      put "/templates/#{template.id}", as: :json,
                                       params: { template: { schema: [pdf_item, *response.parsed_body['schema']] } }
    end

    it 'refuses the dashboard recipients form with the alert and creates no submission' do
      expect(Templates.documents_status(template.reload)).to eq('converting')

      expect do
        post "/templates/#{template.id}/submissions", params: {
          submission: { '1' => { submitters: [{ uuid: template.submitters.first['uuid'],
                                                email: 'signer@example.com' }] } }
        }
      end.not_to change(Submission, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(converting_message)
      expect(Submitter.count).to eq(0)
    end

    it 'refuses MCP send_documents with the message and creates no submission' do
      expect(Templates.documents_status(template.reload)).to eq('converting')

      mcp_token = user.mcp_tokens.create!(name: 'Golden')
      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)

      call = { name: 'send_documents',
               arguments: { template_id: template.id, submitters: [{ role:, email: 'signer@example.com' }] } }

      expect do
        post '/mcp', headers: { 'Authorization' => "Bearer #{mcp_token.token}", **json_headers },
                     params: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: call }.to_json
      end.not_to change(Submission, :count)

      expect(response).to have_http_status(:ok)

      result = response.parsed_body['result']
      expect(result['isError']).to be(true)
      expect(result['content'].sole['text']).to eq(converting_message)
      expect(Submitter.count).to eq(0)
    end

    it 'refuses an embedded signing session with 422 and the message and creates no submission' do
      expect(Templates.documents_status(template.reload)).to eq('converting')

      expect do
        post '/api/signing_sessions', headers: { 'x-auth-token': user.access_token.token, **json_headers },
                                      params: { template_id: template.id,
                                                embed_origin: 'https://app.example.com',
                                                submitters: [{ role:, email: 'signer@example.com' }] }.to_json
      end.not_to change(Submission, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => converting_message)
      expect(Submitter.count).to eq(0)
    end
  end

  describe 'a converting document the template no longer lists' do
    let!(:account) { create(:account, :internal) }
    let(:api_headers) { { 'x-auth-token': user.access_token.token, 'CONTENT_TYPE' => 'application/json' } }
    let(:template) { create(:template, account:, author: user, only_field_types: %w[text]) }
    let(:pdf_item) { template.schema.sole.deep_dup }

    before do
      sign_in(user)
    end

    def add_word_document
      post "/templates/#{template.id}/documents", params: { files: [docx_upload] }

      template.documents.find_by!(uuid: response.parsed_body['schema'].sole['attachment_uuid'])
    end

    def post_api_submission
      post '/api/submissions', headers: api_headers, params: {
        template_id: template.id, submitters: [{ email: 'signer@example.com' }]
      }.to_json
    end

    it 'unblocks sending as soon as the builder removes it from the schema' do
      attachment = add_word_document
      word_item = response.parsed_body['schema'].sole

      put "/templates/#{template.id}", as: :json, params: { template: { schema: [pdf_item, word_item] } }

      # The timed-out card appears after five minutes: a listed document
      # blocks however old it is.
      attachment.update_columns(created_at: 5.minutes.ago)

      expect(Templates.documents_status(template.reload)).to eq('converting')

      post_api_submission

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => I18n.t('documents_still_converting'))

      # Remove: the schema is spliced, the attachment stays converting in storage.
      put "/templates/#{template.id}", as: :json, params: { template: { schema: [pdf_item] } }

      expect(response).to have_http_status(:ok)
      expect(attachment.reload.metadata['converting']).to be(true)
      expect(Templates.documents_status(template.reload)).to be_nil

      expect { post_api_submission }.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)
    end

    it 'still blocks while it is fresh (the builder has not saved the schema yet), not once it is old' do
      attachment = add_word_document

      expect(Templates.documents_status(template.reload)).to eq('converting')

      post_api_submission

      expect(response).to have_http_status(:unprocessable_content)

      attachment.update_columns(created_at: (Templates::CONVERSION_UNLISTED_GRACE + 1.second).ago)

      expect(Templates.documents_status(template.reload)).to be_nil

      # The grace runs from the attachment record, not its blob: the job
      # swapping a brand-new PDF blob into a removed document (half-way
      # through, before its final save fails) must not block sending again.
      attachment.blob.update_columns(created_at: Time.current)

      expect(Templates.documents_status(template.reload)).to be_nil

      expect { post_api_submission }.to change(Submission, :count).by(1)
    end

    it 'is skipped by the job without a LibreOffice run, while a fresh unlisted one still converts' do
      allow(WordConverter).to receive(:call).and_call_original

      removed = add_word_document
      removed_args = ConvertWordDocumentJob.jobs.sole['args'].first
      ConvertWordDocumentJob.jobs.clear
      removed.update_columns(created_at: (Templates::CONVERSION_UNLISTED_GRACE + 1.second).ago)

      ConvertWordDocumentJob.new.perform(removed_args)

      expect(WordConverter).not_to have_received(:call)
      removed.reload
      expect(removed.content_type).to eq(docx_type)
      expect(removed.metadata).to include('converting' => true)
      expect(removed.metadata['conversion_started_at']).to be_nil

      fresh = add_word_document
      ConvertWordDocumentJob.drain

      expect(WordConverter).to have_received(:call).once
      expect(fresh.reload.content_type).to eq('application/pdf')
      expect(fresh.metadata['converting']).to be_nil
    end

    # The stale clock (30 minutes, then "failed") runs from the last sign of
    # progress: LibreOffice being started on the document, or the half-way
    # PDF being stored — not from an upload that sat in a backed-up queue,
    # and not from the busy retries spent waiting for a conversion slot.
    it 'measures the stale clock from when the conversion started, not the upload or the slot wait' do
      attachment = add_word_document
      job_args = ConvertWordDocumentJob.jobs.sole['args'].first
      ConvertWordDocumentJob.jobs.clear
      put "/templates/#{template.id}", as: :json,
                                       params: { template: { schema: [pdf_item, response.parsed_body['schema'].sole] } }

      # Nothing has run yet: the upload time is all there is to go by.
      attachment.blob.update_columns(created_at: (Templates::CONVERSION_STALE_AFTER + 1.minute).ago)

      expect(Templates.documents_status(template.reload)).to eq('failed')

      # Every slot taken: the run is a busy retry and leaves no stamp.
      WordConverter.slot_keys.each { |key| RateLimit.store.write(key, 'another-worker', expires_in: 1.minute) }

      ConvertWordDocumentJob.new.perform(job_args)

      expect(ConvertWordDocumentJob.jobs.sole['args'].first).to include('busy_retries' => 1)
      expect(attachment.reload.metadata['conversion_started_at']).to be_nil
      expect(Templates.documents_status(template.reload)).to eq('failed')

      # A slot is free: the stamp is written inside it, right before
      # LibreOffice runs — here the run dies with a transient error after
      # that, so Sidekiq retries it and the stamp stays.
      RateLimit.store.clear
      allow(WordConverter).to receive(:call) do
        expect(attachment.reload.metadata['conversion_started_at']).to be_present

        raise IOError, 'storage hiccup'
      end

      expect { ConvertWordDocumentJob.new.perform(job_args) }.to raise_error(IOError, 'storage hiccup')

      attachment.reload
      expect(Time.zone.parse(attachment.metadata['conversion_started_at'])).to be_within(1.minute).of(Time.current)
      expect(Templates.documents_status(template.reload)).to eq('converting')
      expect(Templates::ConversionStatus.call(template, attachment.uuid)).to include(status: 'converting')

      # Thirty minutes after that start with no further progress: failed.
      attachment.metadata['conversion_started_at'] = (Templates::CONVERSION_STALE_AFTER + 1.minute).ago.iso8601
      attachment.save!

      expect(Templates.documents_status(template.reload)).to eq('failed')
      expect(Templates::ConversionStatus.call(template, attachment.uuid)).to include(status: 'failed')

      # A PDF stored half-way through is progress too (the later of the two counts).
      attachment.blob.update_columns(created_at: Time.current)

      expect(Templates.documents_status(template.reload)).to eq('converting')
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
