# frozen_string_literal: true

describe 'Signing Sessions API' do
  let(:account) { create(:account, :paid) }
  let(:author) { create(:user, account:) }
  let(:pdf_base64) { Base64.encode64(Rails.root.join('spec/fixtures/sample-document.pdf').read) }
  let(:headers) { { 'x-auth-token': author.access_token.token } }

  describe 'POST /api/signing_sessions' do
    it 'creates an embeddable signing session from a generated PDF' do
      expect do
        post '/api/signing_sessions', headers: headers, params: {
          name: 'Application A Disclosure',
          external_id: 'app-a-workflow-123',
          embed_origin: 'https://app-a.example.com',
          documents: [{ name: 'disclosure.pdf', file: pdf_base64 }],
          submitters: [{ name: 'Borrower', email: 'borrower@example.com', external_id: 'borrower-123' }],
          fields: [
            { name: 'Borrower Signature', type: 'signature', role: 'Borrower',
              areas: [{ x: 0.1, y: 0.8, w: 0.3, h: 0.06, page: 0, document: 0 }] },
            { name: 'Signed Date', type: 'date', role: 'Borrower', readonly: true, default_value: '{{date}}',
              areas: [{ x: 0.72, y: 0.8, w: 0.18, h: 0.04, page: 0, document: 0 }] }
          ],
          metadata: { source_record_id: 'workflow-123' }
        }.to_json
      end.to change(Template, :count).by(1).and change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)

      submission = Submission.last
      submitter = submission.submitters.first
      template = Template.last

      expect(submission.source).to eq('embed')
      expect(submission.preferences).to include(
        'embed_origin' => 'https://app-a.example.com',
        'signing_session_external_id' => 'app-a-workflow-123',
        'metadata' => { 'source_record_id' => 'workflow-123' }
      )
      expect(submitter.preferences['send_email']).to be(false)
      expect(submitter.sent_at).to be_nil
      expect(submitter.metadata).to include(
        'source_record_id' => 'workflow-123',
        'signing_session_external_id' => 'app-a-workflow-123'
      )
      expect(template.fields.pluck('type')).to eq(%w[signature date])

      body = response.parsed_body

      expect(body['id']).to eq(submission.id)
      expect(body['submission_id']).to eq(submission.id)
      expect(body['template_id']).to eq(template.id)
      expect(body['status']).to eq('pending')
      expect(body['embed_src']).to eq(body.dig('submitters', 0, 'embed_src'))
      expect(body['embed_src']).to include("/s/#{submitter.slug}")
      expect(body['documents_url']).to include("/api/submissions/#{submission.id}/documents")
      expect(body['status_url']).to include("/api/signing_sessions/#{submission.id}")
    end

    it 'creates an embeddable signing session from an existing template' do
      template = create(:template, account:, author:)
      template_count = Template.count

      expect do
        post '/api/signing_sessions', headers: headers, params: {
          template_id: template.id,
          embed_origin: 'https://app-a.example.com',
          submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
        }.to_json
      end.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(Template.count).to eq(template_count)
      expect(Submission.last.source).to eq('embed')
      expect(response.parsed_body['template_id']).to eq(template.id)
      expect(response.parsed_body['embed_src']).to include("/s/#{Submission.last.submitters.first.slug}")
    end

    it 'accepts a PNG signature image for the embedded signer and result renderer' do
      template = create(:template, account:, author:, only_field_types: %w[signature])
      signature_data = Rails.root.join('spec/fixtures/sample-image.png').binread
      signature_data_url = "data:image/png;base64,#{Base64.strict_encode64(signature_data)}"

      post '/api/signing_sessions', headers: headers, params: {
        template_id: template.id,
        embed_origin: 'https://app-a.example.com',
        submitters: [{
          role: 'First Party',
          email: 'borrower@example.com',
          values: { Signature: signature_data_url }
        }]
      }.to_json

      expect(response).to have_http_status(:ok)

      submitter = Submission.last.submitters.first
      signature_field = template.fields.find { |field| field['type'] == 'signature' }
      signature_attachment = submitter.attachments.find_by!(uuid: submitter.values[signature_field['uuid']])

      expect(signature_attachment.content_type).to eq('image/png')
      expect(signature_attachment.download).to eq(signature_data)

      get "/s/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(signature_attachment.uuid)
      form = Nokogiri::HTML(response.body).at_css('submission-form')
      attachments = JSON.parse(form['data-attachments'])
      rendered_signature = attachments.find { |attachment| attachment['uuid'] == signature_attachment.uuid }
      expect(rendered_signature).to be_present
      expect(rendered_signature['url']).to be_present

      get URI(rendered_signature['url']).request_uri

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('image/png')
      expect(response.body.b).to eq(signature_data)

      platform_certificate!
      consent = JSON.parse(form['data-esign-consent'])
      get consent.fetch('pdf_url')
      follow_redirect! if response.redirect?
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/pdf')

      # Finish through the same route as the embedded signer. Its first save
      # snapshots the template before the completion worker renders the PDF.
      put "/s/#{submitter.slug}", params: {
        completed: 'true', esign_consent: 'true', esign_consent_pdf_opened: 'true',
        esign_consent_version: consent.fetch('version'), esign_consent_locale: consent.fetch('locale'),
        esign_consent_locale_token: consent.fetch('locale_token'),
        esign_consent_sender_digest: consent.fetch('sender_digest'),
        values: { signature_field['uuid'] => signature_attachment.uuid }
      }
      expect(response).to have_http_status(:ok)
      expect(submitter.reload.completed_at).to be_present
      expect(submitter.submission.reload.template_schema).to be_present

      expect { Submissions::GenerateResultAttachments.call(submitter.reload) }.not_to raise_error

      result_pdf = HexaPDF::Document.new(io: StringIO.new(submitter.reload.documents.first.download))

      expect(result_pdf.images.count).to be_positive
    end

    # Same rule as POST /api/submissions: the uuid is the signing role, and two
    # entries resolving to one used to reach the database and come back as a
    # 500 (review 2, H3). Refuse the duplicate before creating any records.
    it 'refuses two submitters that name the same uuid, creating nothing' do
      template = create(:template, account:, author:, submitter_count: 2)
      shared_uuid = template.submitters.first['uuid']

      expect do
        post '/api/signing_sessions', headers: headers, params: {
          template_id: template.id,
          embed_origin: 'https://app-a.example.com',
          submitters: [
            { uuid: shared_uuid, role: 'First Party', email: 'first@example.com' },
            { uuid: shared_uuid, role: 'Second Party', email: 'second@example.com' }
          ]
        }.to_json
      end.not_to change(Submission, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq({ 'error' => 'uuid must be unique in `submitters`.' })
    end

    it 'rejects existing templates without fields' do
      template = create(:template, account:, author:)
      template.update!(fields: [])

      expect do
        post '/api/signing_sessions', headers: headers, params: {
          template_id: template.id,
          embed_origin: 'https://app-a.example.com',
          submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
        }.to_json
      end.not_to change(Submission, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq({ 'error' => 'Template does not contain fields' })
    end

    it 'rejects generated documents without signing fields' do
      image_base64 = Base64.encode64(Rails.root.join('spec/fixtures/sample-image.png').read)

      expect do
        post '/api/signing_sessions', headers: headers, params: {
          name: 'Application A Disclosure',
          embed_origin: 'https://app-a.example.com',
          documents: [{ name: 'disclosure.png', file: image_base64 }],
          submitters: [{ name: 'Borrower', email: 'borrower@example.com' }],
          fields: []
        }.to_json
      end.not_to change(Submission, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq({ 'error' => 'Template does not contain fields' })
    end

    it 'rate limits signing session creation per account' do
      template = create(:template, account:, author:)

      stub_const('Api::SigningSessionsController::CREATE_RATE_LIMIT', 1)
      RateLimit.store.clear

      2.times do
        post '/api/signing_sessions', headers: headers, params: {
          template_id: template.id,
          embed_origin: 'https://app-a.example.com',
          submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
        }.to_json
      end

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body).to eq({ 'error' => 'Too many requests' })
    ensure
      RateLimit.store.clear
    end

    it 'requires an embed origin so signer links are only framed by the calling app' do
      post '/api/signing_sessions', headers: headers, params: {
        documents: [{ name: 'disclosure.pdf', file: pdf_base64 }],
        submitters: [{ name: 'Borrower', email: 'borrower@example.com' }],
        fields: [
          { name: 'Borrower Signature', type: 'signature', role: 'Borrower',
            areas: [{ x: 0.1, y: 0.8, w: 0.3, h: 0.06, page: 0, document: 0 }] }
        ]
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq({ 'error' => 'embed_origin is required' })
    end

    it 'rejects non-local http embed origins' do
      post '/api/signing_sessions', headers: headers, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'http://app-a.example.com',
        submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('embed_origin must be an https origin')
    end

    it 'allows local http embed origins for development' do
      post '/api/signing_sessions', headers: headers, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'http://localhost:3000',
        submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(Submission.last.preferences['embed_origin']).to eq('http://localhost:3000')
    end

    it 'normalizes IPv6 localhost embed origins for development' do
      post '/api/signing_sessions', headers: headers, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'http://[::1]:3000',
        submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(Submission.last.preferences['embed_origin']).to eq('http://[::1]:3000')
    end

    it 'normalizes embed origins with a trailing slash' do
      post '/api/signing_sessions', headers: headers, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://app-a.example.com/',
        submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
      }.to_json

      expect(response).to have_http_status(:ok)
      expect(Submission.last.preferences['embed_origin']).to eq('https://app-a.example.com')
    end

    it 'returns fresh completed data when the embedded signer finishes' do
      post '/api/signing_sessions', headers: headers, params: {
        template_id: create(:template, account:, author:, only_field_types: ['text']).id,
        embed_origin: 'https://app-a.example.com',
        submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
      }.to_json

      submitter = Submission.last.submitters.first
      field = submitter.submission.template.fields.first

      put "/s/#{submitter.slug}", params: {
        completed: 'true',
        esign_consent: 'true',
        esign_consent_version: EsignConsent::VERSION,
        esign_consent_locale: EsignConsent.rendered_locale,
        esign_consent_locale_token:
          EsignConsent.locale_token(submitter, EsignConsent.rendered_locale),
        esign_consent_sender_digest: EsignConsent.sender_digest(submitter),
        timezone: 'America/Chicago',
        values: { field['uuid'] => 'Jane' }
      }

      expect(response).to have_http_status(:ok)

      body = response.parsed_body

      expect(body.dig('submitter', 'id')).to eq(submitter.id)
      expect(body.dig('submitter', 'status')).to eq('completed')
      expect(body.dig('submitter', 'completed_at')).to be_present
      expect(body.dig('signing_session', 'id')).to eq(submitter.submission_id)
      expect(body.dig('signing_session', 'status')).to eq('completed')
      expect(body.dig('signing_session', 'completed_at')).to be_present
    end
  end

  describe 'GET /api/signing_sessions/:id' do
    it 'returns signing session status' do
      post '/api/signing_sessions', headers: headers, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://app-a.example.com',
        submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
      }.to_json

      submission_id = response.parsed_body['id']

      get "/api/signing_sessions/#{submission_id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        'id' => submission_id,
        'submission_id' => submission_id,
        'status' => 'pending'
      )
      expect(response.parsed_body['embed_src']).to include('/s/')
    end
  end

  describe 'GET /s/:slug' do
    it 'allows framing only for the configured App A origin' do
      post '/api/signing_sessions', headers: headers, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://app-a.example.com',
        submitters: [{ role: 'First Party', email: 'borrower@example.com' }]
      }.to_json

      allow_any_instance_of(SubmitFormController).to receive(:show) { |controller| controller.head(:ok) }

      get URI.parse(response.parsed_body['embed_src']).path

      expect(response).to have_http_status(:ok)
      expect(response.headers['X-Frame-Options']).to be_nil
      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'self' https://app-a.example.com")
    end
  end
end
