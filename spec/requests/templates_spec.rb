# frozen_string_literal: true

describe 'Templates API' do
  let(:account) { create(:account, :with_testing_account) }
  let(:testing_account) { account.testing_accounts.first }
  let(:author) { create(:user, account:) }
  let(:testing_author) { create(:user, account: testing_account) }
  let(:folder) { create(:template_folder, account:) }
  let(:template_preferences) { { 'request_email_subject' => 'Subject text', 'request_email_body' => 'Body Text' } }

  before do
    allow(Accounts).to receive(:link_expires_at).and_return(Accounts::LINK_EXPIRES_AT)
  end

  describe 'GET /api/templates' do
    it 'returns a list of templates' do
      templates = [
        create(:template, account:,
                          author:,
                          folder:,
                          external_id: SecureRandom.base58(10),
                          preferences: template_preferences),
        create(:template, account:,
                          author:,
                          folder:,
                          external_id: SecureRandom.base58(10),
                          preferences: template_preferences)
      ].reverse

      get '/api/templates', headers: { 'x-auth-token': author.access_token.token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['pagination']).to eq(JSON.parse({
        count: templates.size,
        next: templates.last.id,
        prev: templates.first.id
      }.to_json))
      expect(response.parsed_body['data']).to eq(JSON.parse(templates.map { |t| template_body(t) }.to_json))
    end
  end

  describe 'GET /api/templates/:id' do
    it 'returns a template' do
      template = create(:template, account:,
                                   author:,
                                   folder:,
                                   external_id: SecureRandom.base58(10),
                                   preferences: template_preferences)

      get "/api/templates/#{template.id}", headers: { 'x-auth-token': author.access_token.token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(JSON.parse(template_body(template).to_json))
    end

    it 'returns an authorization error if test account API token is used with a production template' do
      template = create(:template, account:,
                                   author:,
                                   folder:,
                                   external_id: SecureRandom.base58(10),
                                   preferences: template_preferences)

      get "/api/templates/#{template.id}", headers: { 'x-auth-token': testing_author.access_token.token }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq(
        JSON.parse({ error: "Template #{template.id} not found using testing API key; " \
                            'Use production API key to access production templates.' }.to_json)
      )
    end

    it 'returns an authorization error if production account API token is used with a test template' do
      template = create(:template, account: testing_account,
                                   author: testing_author,
                                   folder:,
                                   external_id: SecureRandom.base58(10),
                                   preferences: template_preferences)

      get "/api/templates/#{template.id}", headers: { 'x-auth-token': author.access_token.token }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq(
        JSON.parse({ error: "Template #{template.id} not found using production API key; " \
                            'Use testing API key to access testing templates.' }.to_json)
      )
    end
  end

  describe 'PUT /api/templates' do
    let(:template) do
      create(:template, account:,
                        author:,
                        folder:,
                        external_id: SecureRandom.base58(10),
                        preferences: template_preferences)
    end

    it 'updates a template' do
      put "/api/templates/#{template.id}", headers: { 'x-auth-token': author.access_token.token }, params: {
        name: 'Updated Template Name',
        external_id: '123456'
      }.to_json

      expect(response).to have_http_status(:ok)

      template.reload

      expect(template.name).to eq('Updated Template Name')
      expect(template.external_id).to eq('123456')
      expect(response.parsed_body).to eq(JSON.parse({
        id: template.id,
        updated_at: template.updated_at
      }.to_json))
    end

    it "enables the template's shared link" do
      expect do
        put "/api/templates/#{template.id}", headers: { 'x-auth-token': author.access_token.token }, params: {
          shared_link: true
        }.to_json
      end.to change { template.reload.shared_link }.from(false).to(true)
    end

    it "disables the template's shared link" do
      template.update(shared_link: true)

      expect do
        put "/api/templates/#{template.id}", headers: { 'x-auth-token': author.access_token.token }, params: {
          shared_link: false
        }.to_json
      end.to change { template.reload.shared_link }.from(true).to(false)
    end
  end

  describe 'DELETE /api/templates/:id' do
    it 'archives a template' do
      template = create(:template, account:,
                                   author:,
                                   folder:,
                                   external_id: SecureRandom.base58(10),
                                   preferences: template_preferences)

      delete "/api/templates/#{template.id}", headers: { 'x-auth-token': author.access_token.token }

      expect(response).to have_http_status(:ok)

      template.reload

      expect(template.archived_at).not_to be_nil
      expect(response.parsed_body).to eq(JSON.parse({
        id: template.id,
        archived_at: template.archived_at
      }.to_json))
    end
  end

  describe 'POST /api/templates/:id/clone' do
    it 'clones a template' do
      template = create(:template, account:,
                                   author:,
                                   folder:,
                                   external_id: SecureRandom.base58(10),
                                   preferences: template_preferences)

      expect do
        post "/api/templates/#{template.id}/clone", headers: { 'x-auth-token': author.access_token.token }, params: {
          name: 'Cloned Template Name',
          external_id: '123456'
        }.to_json
      end.to change(Template, :count)

      expect(response).to have_http_status(:ok)

      cloned_template = Template.last

      expect(cloned_template.name).to eq('Cloned Template Name')
      expect(cloned_template.external_id).to eq('123456')
      expect(response.parsed_body).to eq(JSON.parse(clone_template_body(cloned_template).to_json))
    end
  end

  describe 'POST /api/templates' do
    let(:pdf_base64) { Base64.encode64(Rails.root.join('spec/fixtures/sample-document.pdf').read) }
    let(:unsupported_format_message) { 'Unsupported document format. Only PDF and image files are supported.' }

    it 'creates a template from a base64-encoded PDF' do
      expect do
        post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
          name: 'Generated Disclosure',
          external_id: 'va-claim-123',
          documents: [{ name: 'disclosure', file: pdf_base64 }]
        }.to_json
      end.to change(Template, :count).by(1)

      expect(response).to have_http_status(:ok)

      template = Template.last
      expect(template.account_id).to eq(account.id)
      expect(template.author_id).to eq(author.id)
      expect(template.source).to eq('api')
      expect(template.name).to eq('Generated Disclosure')
      expect(template.external_id).to eq('va-claim-123')
      expect(template.schema.size).to eq(1)

      expect(response.parsed_body['name']).to eq('Generated Disclosure')
      expect(response.parsed_body['documents'].size).to eq(1)
      expect(response.parsed_body['documents'].first['uuid']).to be_present
    end

    it 'creates a template with explicit submitters and placed fields' do
      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        name: 'Veteran Authorization',
        documents: [{ name: 'auth', file: pdf_base64 }],
        submitters: [{ name: 'Veteran' }, { name: 'Witness' }],
        fields: [
          { name: 'Veteran Signature', type: 'signature', role: 'Veteran', required: true,
            areas: [{ x: 0.1, y: 0.8, w: 0.3, h: 0.05, page: 0, document: 0 }] }
        ]
      }.to_json

      expect(response).to have_http_status(:ok)

      template = Template.last
      veteran_uuid = template.submitters.find { |submitter| submitter['name'] == 'Veteran' }['uuid']
      document_uuid = template.schema.first['attachment_uuid']
      field = template.fields.first

      expect(template.submitters.pluck('name')).to eq(%w[Veteran Witness])
      expect(template.fields.size).to eq(1)
      expect(field['name']).to eq('Veteran Signature')
      expect(field['type']).to eq('signature')
      expect(field['required']).to be(true)
      expect(field['submitter_uuid']).to eq(veteran_uuid)
      expect(field['areas'].first['attachment_uuid']).to eq(document_uuid)
      expect(field['areas'].first).to include('x' => 0.1, 'y' => 0.8, 'w' => 0.3, 'h' => 0.05, 'page' => 0)
    end

    it 'wires option_uuid for radio fields so selections render on the signed PDF' do
      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ name: 'form', file: pdf_base64 }],
        submitters: [{ name: 'Veteran' }],
        fields: [
          { name: 'Gender', type: 'radio', role: 'Veteran',
            options: [{ value: 'Male' }, { value: 'Female' }],
            areas: [
              { x: 0.1, y: 0.1, w: 0.05, h: 0.03, page: 0, document: 0, option: 'Male' },
              { x: 0.1, y: 0.2, w: 0.05, h: 0.03, page: 0, document: 0, option: 'Female' }
            ] }
        ]
      }.to_json

      expect(response).to have_http_status(:ok)

      field = Template.last.fields.first
      male_uuid = field['options'].find { |option| option['value'] == 'Male' }['uuid']
      female_uuid = field['options'].find { |option| option['value'] == 'Female' }['uuid']

      expect(field['type']).to eq('radio')
      expect(field['options'].pluck('value')).to eq(%w[Male Female])
      expect(field['areas'][0]['option_uuid']).to eq(male_uuid)
      expect(field['areas'][1]['option_uuid']).to eq(female_uuid)
    end

    it 'resolves radio option areas referenced by integer index' do
      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ file: pdf_base64 }],
        submitters: [{ name: 'Veteran' }],
        fields: [
          { name: 'Choice', type: 'radio', role: 'Veteran',
            options: [{ value: 'A' }, { value: 'B' }],
            areas: [
              { x: 0.1, y: 0.1, w: 0.03, h: 0.03, page: 0, option: 0 },
              { x: 0.1, y: 0.2, w: 0.03, h: 0.03, page: 0, option: 1 }
            ] }
        ]
      }.to_json

      expect(response).to have_http_status(:ok)

      field = Template.last.fields.first
      expect(field['areas'][0]['option_uuid']).to eq(field['options'][0]['uuid'])
      expect(field['areas'][1]['option_uuid']).to eq(field['options'][1]['uuid'])
    end

    it 'rejects fields with blank option values' do
      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ file: pdf_base64 }],
        submitters: [{ name: 'Veteran' }],
        fields: [
          { name: 'Choice', type: 'radio', role: 'Veteran',
            options: [{ value: '' }, { value: 'B' }],
            areas: [{ x: 0.1, y: 0.1, w: 0.03, h: 0.03, page: 0, option: 'B' }] }
        ]
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to match(/option value is required/)
    end

    it 'rejects a non-integer page number' do
      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ file: pdf_base64 }],
        submitters: [{ name: 'Veteran' }],
        fields: [
          { name: 'Signature', type: 'signature', role: 'Veteran',
            areas: [{ x: 0.1, y: 0.1, w: 0.1, h: 0.05, page: 1.5, document: 0 }] }
        ]
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to match(/page must be a non-negative integer/)
    end

    it 'rejects field coordinates outside the 0..1 range' do
      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ file: pdf_base64 }],
        submitters: [{ name: 'Veteran' }],
        fields: [
          { name: 'Signature', type: 'signature', role: 'Veteran',
            areas: [{ x: 1.5, y: 0.1, w: 0.1, h: 0.05, page: 0, document: 0 }] }
        ]
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to match(/must be a number between 0 and 1/)
    end

    it 'maps each field area to the correct document by index' do
      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ name: 'first', file: pdf_base64 }, { name: 'second', file: pdf_base64 }],
        submitters: [{ name: 'Veteran' }],
        fields: [
          { name: 'Signature', type: 'signature', role: 'Veteran',
            areas: [{ x: 0.1, y: 0.8, w: 0.2, h: 0.05, page: 0, document: 1 }] }
        ]
      }.to_json

      expect(response).to have_http_status(:ok)

      template = Template.last
      expect(template.schema.size).to eq(2)
      expect(template.fields.first['areas'].first['attachment_uuid']).to eq(template.schema[1]['attachment_uuid'])
    end

    it 'creates a template from an image and leaves fields empty when none are detected' do
      png_base64 = Base64.encode64(Rails.root.join('spec/fixtures/sample-image.png').read)

      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ name: 'scan', file: png_base64 }]
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(Template.last.fields).to eq([])
    end

    it 'rejects a field whose role does not match any submitter' do
      expect do
        post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
          documents: [{ file: pdf_base64 }],
          submitters: [{ name: 'Veteran' }],
          fields: [
            { name: 'Signature', type: 'signature', role: 'Ghost',
              areas: [{ x: 0.1, y: 0.1, w: 0.1, h: 0.05, page: 0, document: 0 }] }
          ]
        }.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to match(/does not match any submitter/)
    end

    it 'rejects duplicate submitter names' do
      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ file: pdf_base64 }],
        submitters: [{ name: 'Signer' }, { name: 'Signer' }]
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to match(/unique/)
    end

    it 'rejects zip uploads without creating a template' do
      zip = Zip::OutputStream.write_buffer do |out|
        out.put_next_entry('a.pdf')
        out.write(Rails.root.join('spec/fixtures/sample-document.pdf').read)
      end

      expect do
        post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
          documents: [{ name: 'bundle.zip', file: Base64.encode64(zip.string) }]
        }.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq(unsupported_format_message)
    end

    it 'requires authentication' do
      post '/api/templates', params: { documents: [{ file: pdf_base64 }] }.to_json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'Not authenticated')
    end

    it 'returns a validation error when no documents are provided' do
      expect do
        post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
          name: 'No documents'
        }.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to be_present
    end

    it 'rejects unsupported document formats without creating a template' do
      docx_base64 = Base64.encode64(Rails.root.join('spec/fixtures/fieldtags.docx').read)

      expect do
        post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
          documents: [{ name: 'contract.docx', file: docx_base64 }]
        }.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq(unsupported_format_message)
    end

    it 'rejects documents that exceed the size limit' do
      stub_const('Api::TemplatesController::MAX_DOCUMENT_SIZE', 8)
      stub_const('Api::TemplatesController::MAX_ENCODED_DOCUMENT_SIZE', 64)

      post '/api/templates', headers: { 'x-auth-token': author.access_token.token }, params: {
        documents: [{ file: Base64.encode64('this is definitely more than eight bytes') }]
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to match(/exceeds the/)
    end
  end

  private

  def template_body(template)
    template_attachment_uuid = template.schema.first['attachment_uuid']
    attachment = template.schema_documents.preload(:blob).find { |e| e.uuid == template_attachment_uuid }
    first_page_blob =
      ActiveStorage::Attachment.joins(:blob)
                               .where(blob: { filename: '0.png' })
                               .where(record_id: template.schema_documents.map(&:id),
                                      record_type: 'ActiveStorage::Attachment',
                                      name: :preview_images)
                               .preload(:blob)
                               .first
                               .blob

    {
      id: template.id,
      slug: template.slug,
      name: template.name,
      fields: template.fields,
      submitters: [
        {
          name: 'First Party',
          uuid: template.submitters.first['uuid']
        }
      ],
      author: {
        id: author.id,
        first_name: author.first_name,
        last_name: author.last_name,
        email: author.email
      },
      documents: [
        {
          id: template.documents.first.id,
          uuid: template.documents.first.uuid,
          url: ActiveStorage::Blob.proxy_url(attachment.blob, expires_at: Accounts::LINK_EXPIRES_AT),
          preview_image_url: ActiveStorage::Blob.proxy_url(first_page_blob, expires_at: Accounts::LINK_EXPIRES_AT),
          filename: 'sample-document.pdf'
        }
      ],
      preferences: {
        'request_email_subject' => 'Subject text',
        'request_email_body' => 'Body Text'
      },
      schema: [
        {
          attachment_uuid: template_attachment_uuid,
          name: 'sample-document'
        }
      ],
      shared_link: template.shared_link,
      author_id: author.id,
      archived_at: nil,
      created_at: template.created_at,
      updated_at: template.updated_at,
      folder_id: folder.id,
      folder_name: folder.name,
      source: 'native',
      external_id: template.external_id,
      application_key: template.external_id
    }
  end

  def clone_template_body(cloned_template)
    body = template_body(cloned_template).merge(source: 'api')
    body[:fields].each_with_index do |field, index|
      field.merge!(
        'submitter_uuid' => cloned_template.fields[index]['submitter_uuid'],
        'uuid' => cloned_template.fields[index]['uuid']
      )
    end

    body
  end
end
