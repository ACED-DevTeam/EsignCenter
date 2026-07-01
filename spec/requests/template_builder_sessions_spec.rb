# frozen_string_literal: true

describe 'Template Builder Sessions API' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:headers) { { 'x-auth-token': author.access_token.token } }
  let(:pdf_base64) { Base64.encode64(Rails.root.join('spec/fixtures/sample-document.pdf').read) }

  describe 'POST /api/template_builder_sessions' do
    it 'creates an embeddable builder session from a generated PDF' do
      expect do
        post '/api/template_builder_sessions', headers:, params: {
          name: 'CRM Listing Agreement',
          external_id: 'crm-template-123',
          folder_name: 'CRM Templates',
          embed_origin: 'https://crm.example.com',
          documents: [{ name: 'listing-agreement.pdf', file: pdf_base64 }],
          submitters: [{ name: 'Client' }],
          metadata: { crm_record_id: 'listing-123' }
        }.to_json
      end.to change(Template, :count).by(1)

      expect(response).to have_http_status(:ok)

      template = Template.last
      body = response.parsed_body

      expect(template.preferences.dig('embed_builder', 'origin')).to eq('https://crm.example.com')
      expect(template.preferences.dig('embed_builder', 'external_id')).to eq('crm-template-123')
      expect(template.preferences.dig('embed_builder', 'metadata')).to eq({ 'crm_record_id' => 'listing-123' })
      expect(body['template_id']).to eq(template.id)
      expect(body['builder_src']).to include('/embed/template_builder/')
      expect(body['signing_session_url']).to include('/api/signing_sessions')
      expect(body['status']).to eq('needs_fields')
    end

    it 'creates an embeddable builder session for an existing template' do
      template = create(:template, account:, author:)

      expect do
        post '/api/template_builder_sessions', headers:, params: {
          template_id: template.id,
          embed_origin: 'https://crm.example.com'
        }.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['template_id']).to eq(template.id)
      expect(template.reload.preferences.dig('embed_builder', 'origin')).to eq('https://crm.example.com')
    end

    it 'does not create an edit-capable builder URL for a read-only shared template' do
      parent_account = create(:account, :with_testing_account)
      testing_account = parent_account.testing_accounts.first
      parent_author = create(:user, account: parent_account)
      testing_editor = create(:user, :editor, account: testing_account)
      template = create(:template, account: parent_account, author: parent_author)

      TemplateSharing.create!(template:, account: testing_account, ability: 'read')

      post '/api/template_builder_sessions', headers: { 'x-auth-token': testing_editor.access_token.token }, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to include('not found using testing API key')
      expect(template.reload.preferences['embed_builder']).to be_blank
    end

    it 'creates an embeddable builder session from a cloned saved template' do
      template = create(:template, account:, author:, only_field_types: %w[signature])

      expect do
        post '/api/template_builder_sessions', headers:, params: {
          clone_template_id: template.id,
          name: 'CRM Client Packet',
          external_id: 'crm-client-packet-123',
          embed_origin: 'https://crm.example.com'
        }.to_json
      end.to change(Template, :count).by(1)

      expect(response).to have_http_status(:ok)

      cloned_template = Template.last
      body = response.parsed_body

      expect(cloned_template.id).not_to eq(template.id)
      expect(cloned_template.name).to eq('CRM Client Packet')
      expect(cloned_template.external_id).to eq('crm-client-packet-123')
      expect(cloned_template.fields.size).to eq(template.fields.size)
      expect(cloned_template.preferences.dig('embed_builder', 'origin')).to eq('https://crm.example.com')
      expect(body['template_id']).to eq(cloned_template.id)
      expect(body['status']).to eq('ready')
    end

    it 'creates an embeddable cloned builder session with generated documents replacing the template PDF' do
      template = create(:template, account:, author:, only_field_types: %w[signature])
      original_attachment_uuid = template.schema.first['attachment_uuid']
      original_area = template.fields.first['areas'].first.except('attachment_uuid')

      expect do
        post '/api/template_builder_sessions', headers:, params: {
          clone_template_id: template.id,
          name: 'Generated CRM Client Packet',
          embed_origin: 'https://crm.example.com',
          documents: [{ name: 'generated-client-packet.pdf', file: pdf_base64 }]
        }.to_json
      end.to change(Template, :count).by(1)

      expect(response).to have_http_status(:ok)

      cloned_template = Template.last
      cloned_attachment_uuid = cloned_template.schema.first['attachment_uuid']

      expect(cloned_attachment_uuid).not_to eq(original_attachment_uuid)
      expect(cloned_template.fields.first['areas'].first['attachment_uuid']).to eq(cloned_attachment_uuid)
      expect(cloned_template.fields.first['areas'].first.except('attachment_uuid')).to eq(original_area)
      expect(response.parsed_body['template_id']).to eq(cloned_template.id)
    end

    it 'does not clone a template from another account' do
      other_account = create(:account)
      other_author = create(:user, account: other_account)
      other_template = create(:template, account: other_account, author: other_author)

      expect do
        post '/api/template_builder_sessions', headers:, params: {
          clone_template_id: other_template.id,
          embed_origin: 'https://crm.example.com'
        }.to_json
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('Template not found')
    end

    it 'rejects non-positive builder session expiration values' do
      [0, -5].each do |expires_in_minutes|
        post '/api/template_builder_sessions', headers:, params: {
          template_id: create(:template, account:, author:).id,
          embed_origin: 'https://crm.example.com',
          expires_in_minutes:
        }.to_json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('expires_in_minutes must be greater than 0')
      end
    end

    it 'caps builder session expiration at 24 hours' do
      post '/api/template_builder_sessions', headers:, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://crm.example.com',
        expires_in_minutes: 10_000
      }.to_json

      expect(response).to have_http_status(:ok)

      expires_at = Time.zone.parse(response.parsed_body['expires_at'])

      expect(expires_at).to be <= 24.hours.from_now
      expect(expires_at).to be > 23.hours.from_now
    end

    it 'rejects non-local http embed origins' do
      post '/api/template_builder_sessions', headers:, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'http://crm.example.com'
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('embed_origin must be an https origin')
    end
  end

  describe 'GET /api/template_builder_sessions/:id' do
    it 'returns builder session status' do
      post '/api/template_builder_sessions', headers:, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      template_id = response.parsed_body['template_id']

      get "/api/template_builder_sessions/#{template_id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        'template_id' => template_id,
        'status' => 'ready'
      )
      expect(response.parsed_body['builder_src']).to include('/embed/template_builder/')
    end

    it 'does not return an edit-capable builder URL to a read-only viewer' do
      template = create(:template, account:, author:)
      viewer = create(:user, :viewer, account:)

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      get "/api/template_builder_sessions/#{template.id}", headers: { 'x-auth-token': viewer.access_token.token }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to eq('Not authorized')
    end

    it 'does not return a builder URL for a normal template without a builder session' do
      template = create(:template, account:, author:)

      get "/api/template_builder_sessions/#{template.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']).to eq('Template builder session not found')
    end

    it 'does not refresh an expired builder session URL' do
      template = create(:template, account:, author:)

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      template.update!(
        preferences: template.reload.preferences.merge(
          'embed_builder' => template.preferences['embed_builder'].merge('expires_at' => 1.minute.ago.iso8601)
        )
      )

      get "/api/template_builder_sessions/#{template.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']).to eq('Template builder session not found')
    end
  end

  describe 'GET /embed/template_builder/:token' do
    it 'allows framing only for the configured CRM origin' do
      post '/api/template_builder_sessions', headers:, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      get URI.parse(response.parsed_body['builder_src']).path

      expect(response).to have_http_status(:ok)
      expect(response.headers['X-Frame-Options']).to be_nil
      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'self' https://crm.example.com")
      expect(response.body).to include('<template-builder')
      expect(response.body).to include('data-embed-origin="https://crm.example.com"')
      expect(response.body).to include('data-with-logo="false"')
      expect(response.body).to match(%r{data-base-url="http://[^"]+/embed/template_builder/})
      expect(response.body).to include(Docuseal.product_name)
      expect(response.body).to include('/embed/template_builder/')
    end

    it 'rejects expired embedded builder sessions' do
      template = create(:template, account:, author:)

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      builder_path = URI.parse(response.parsed_body['builder_src']).path
      template.update!(
        preferences: template.preferences.merge(
          'embed_builder' => template.reload.preferences['embed_builder'].merge('expires_at' => 1.minute.ago.iso8601)
        )
      )

      expect { get builder_path }.to raise_error(ActionController::RoutingError)
    end

    it 'saves template fields through the tokenized embedded builder route without EsignCenter login' do
      template = create(:template, account:, author:, only_field_types: ['text'])

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      token = URI.parse(response.parsed_body['builder_src']).path.split('/').last
      field = template.fields.first
      field['name'] = 'Client Legal Name'

      put "/embed/template_builder/#{token}/templates/#{template.id}", params: {
        template: {
          name: 'Updated CRM Agreement',
          schema: template.schema,
          submitters: template.submitters,
          fields: [field],
          variables_schema: {}
        }
      }.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(template.reload.name).to eq('Updated CRM Agreement')
      expect(template.fields.first['name']).to eq('Client Legal Name')
    end

    it 'does not allow a builder token for one template to update another template' do
      template = create(:template, account:, author:)
      other_template = create(:template, account:, author:)

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      token = URI.parse(response.parsed_body['builder_src']).path.split('/').last

      expect do
        put "/embed/template_builder/#{token}/templates/#{other_template.id}", params: {
          template: {
            name: 'Wrong Template Update',
            schema: other_template.schema,
            submitters: other_template.submitters,
            fields: other_template.fields,
            variables_schema: {}
          }
        }.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
      end.to raise_error(ActionController::RoutingError)

      expect(other_template.reload.name).not_to eq('Wrong Template Update')
    end

    it 'does not allow a builder token for one template to read or mutate another template documents' do
      template = create(:template, account:, author:)
      other_template = create(:template, account:, author:)

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      token = URI.parse(response.parsed_body['builder_src']).path.split('/').last

      expect do
        get "/embed/template_builder/#{token}/templates/#{other_template.id}/documents"
      end.to raise_error(ActionController::RoutingError)

      expect do
        post "/embed/template_builder/#{token}/templates/#{other_template.id}/documents", params: {
          files: [fixture_file_upload(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png')]
        }
      end.to raise_error(ActionController::RoutingError)

      expect do
        post "/embed/template_builder/#{token}/templates/#{other_template.id}/detect_fields", params: {
          attachment_uuid: other_template.schema.first['attachment_uuid'],
          page: 0
        }.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
      end.to raise_error(ActionController::RoutingError)
    end

    it 'rejects embedded builder writes from a different browser origin' do
      template = create(:template, account:, author:, only_field_types: ['text'])

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      token = URI.parse(response.parsed_body['builder_src']).path.split('/').last

      put "/embed/template_builder/#{token}/templates/#{template.id}", params: {
        template: {
          name: 'Evil Update',
          schema: template.schema,
          submitters: template.submitters,
          fields: template.fields,
          variables_schema: {}
        }
      }.to_json, headers: { 'CONTENT_TYPE' => 'application/json', 'Origin' => 'https://evil.example.com' }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to eq('Invalid embed origin')
      expect(template.reload.name).not_to eq('Evil Update')
    end

    it 'uploads documents through the tokenized embedded builder route without EsignCenter login' do
      template = create(:template, account:, author:)

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      token = URI.parse(response.parsed_body['builder_src']).path.split('/').last

      expect do
        post "/embed/template_builder/#{token}/templates/#{template.id}/documents", params: {
          files: [fixture_file_upload(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png')]
        }
      end.to change { template.reload.documents.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['documents'].first['id']).to be_present
    end
  end

  describe 'builder-to-signing handoff' do
    it 'uses a ready builder session template to create an embedded signing session' do
      template = create(:template, account:, author:, only_field_types: %w[signature])

      post '/api/template_builder_sessions', headers:, params: {
        template_id: template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      template_id = response.parsed_body['template_id']

      post '/api/signing_sessions', headers:, params: {
        template_id:,
        embed_origin: 'https://crm.example.com',
        submitters: [{ role: template.submitters.first['name'], email: 'client@example.com' }]
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['template_id']).to eq(template_id)
      expect(response.parsed_body['embed_src']).to include('/s/')
      expect(response.parsed_body['documents_url']).to include('/api/submissions/')
    end
  end
end
