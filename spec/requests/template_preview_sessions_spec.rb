# frozen_string_literal: true

describe 'Template Preview Sessions API' do
  let(:account) { create(:account, :internal) }
  let(:author) { create(:user, account:) }
  let(:headers) { { 'x-auth-token': author.access_token.token } }

  def create_preview_session(params)
    post '/api/template_preview_sessions', headers:, params: params.to_json

    response.parsed_body
  end

  describe 'POST /api/template_preview_sessions' do
    it 'returns a preview URL without creating a submission or submitter' do
      template = create(:template, account:, author:)

      expect do
        post '/api/template_preview_sessions', headers:, params: {
          template_id: template.id,
          embed_origin: 'https://crm.example.com'
        }.to_json
      end.not_to change(Template, :count)

      expect(Submission.count).to eq(0)
      expect(Submitter.count).to eq(0)
      expect(response).to have_http_status(:ok)

      body = response.parsed_body

      expect(body['template_id']).to eq(template.id)
      expect(body['token']).to be_present
      expect(body['id']).to eq(body['token'])
      expect(body['embed_origin']).to eq('https://crm.example.com')
      expect(body['preview_src']).to include("/embed/template_preview/#{body['token']}")
      expect(Time.zone.parse(body['expires_at'])).to be_between(1.hour.from_now, 3.hours.from_now)
    end

    it 'caps preview session expiration at 24 hours' do
      post '/api/template_preview_sessions', headers:, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://crm.example.com',
        expires_in_minutes: 10_000
      }.to_json

      expect(response).to have_http_status(:ok)

      expires_at = Time.zone.parse(response.parsed_body['expires_at'])

      expect(expires_at).to be <= 24.hours.from_now
      expect(expires_at).to be > 23.hours.from_now
    end

    it 'does not mint a preview session for a template from another account' do
      other_account = create(:account)
      other_author = create(:user, account: other_account)
      other_template = create(:template, account: other_account, author: other_author)

      post '/api/template_preview_sessions', headers:, params: {
        template_id: other_template.id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']).to eq('Template not found')
    end

    it 'does not mint a preview session for a template merely SHARED into this account' do
      parent_account = create(:account, :internal, :with_testing_account)
      testing_account = parent_account.testing_accounts.first
      parent_author = create(:user, account: parent_account)
      testing_editor = create(:user, :editor, account: testing_account)
      template = create(:template, account: parent_account, author: parent_author)

      TemplateSharing.create!(template:, account: testing_account, ability: 'read')

      # Without the account-ownership check this template IS readable by the
      # testing account, which is exactly why the check has to exist: a preview
      # token is a login-free URL to the template's full contents.
      expect(Template.accessible_by(Ability.new(testing_editor), :read).exists?(template.id)).to be(true)

      post '/api/template_preview_sessions',
           headers: { 'x-auth-token': testing_editor.access_token.token },
           params: { template_id: template.id, embed_origin: 'https://crm.example.com' }.to_json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']).to eq('Template not found')
    end

    it 'requires an API token' do
      post '/api/template_preview_sessions', params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://crm.example.com'
      }.to_json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects non-local http embed origins' do
      post '/api/template_preview_sessions', headers:, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'http://crm.example.com'
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('embed_origin must be an https origin')
    end

    it 'rejects non-string dummy values' do
      post '/api/template_preview_sessions', headers:, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://crm.example.com',
        values: { 'some-field-uuid' => 42 }
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('must be a String')
    end

    it 'rejects more dummy values than the cap allows' do
      values = Array.new(201) { |i| ["field-#{i}", 'x'] }.to_h

      post '/api/template_preview_sessions', headers:, params: {
        template_id: create(:template, account:, author:).id,
        embed_origin: 'https://crm.example.com',
        values:
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('200 items or fewer')
    end

    # The whole preview token travels in a URL, so the payload it carries is
    # capped well under the request-line limit every proxy enforces.
    it 'accepts dummy values exactly at the 4 KB cap and rejects one byte more' do
      template = create(:template, account:, author:)
      field_uuid = template.fields.first['uuid']

      overhead = { field_uuid => '' }.to_json.bytesize
      at_cap = { field_uuid => 'x' * (4096 - overhead) }

      expect(at_cap.to_json.bytesize).to eq(4096)

      post '/api/template_preview_sessions', headers:, params: {
        template_id: template.id, embed_origin: 'https://crm.example.com', values: at_cap
      }.to_json

      expect(response).to have_http_status(:ok)

      over_cap = { field_uuid => 'x' * (4097 - overhead) }

      expect(over_cap.to_json.bytesize).to eq(4097)

      post '/api/template_preview_sessions', headers:, params: {
        template_id: template.id, embed_origin: 'https://crm.example.com', values: over_cap
      }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('values must be 4096 bytes or fewer')
    end
  end

  describe 'GET /embed/template_preview/:token' do
    it 'renders a read-only signing form preview with no login and no writes' do
      template = create(:template, account:, author:)

      body = create_preview_session(template_id: template.id, embed_origin: 'https://crm.example.com')

      get URI.parse(body['preview_src']).path

      expect(Submission.count).to eq(0)
      expect(Submitter.count).to eq(0)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<submission-form')
      expect(response.body).to include('data-dry-run="true"')
      expect(response.body).to include(CGI.escapeHTML(template.name))
      expect(response.body).not_to include("/templates/#{template.id}/edit")
    end

    it 'paints the dummy values into the preview' do
      template = create(:template, account:, author:, submitter_count: 2, only_field_types: %w[text])
      first_party_field, second_party_field = template.fields.first(2)

      body = create_preview_session(
        template_id: template.id,
        embed_origin: 'https://crm.example.com',
        values: {
          first_party_field['uuid'] => 'Jamie Borrower',
          second_party_field['uuid'] => 'Alex Lender'
        }
      )

      get URI.parse(body['preview_src']).path

      expect(response).to have_http_status(:ok)
      # The current submitter's own editable fields are painted by the signing
      # form component, the other party's by the static page layer.
      expect(response.body).to include(CGI.escapeHTML({ first_party_field['uuid'] => 'Jamie Borrower',
                                                        second_party_field['uuid'] => 'Alex Lender' }.to_json))
      expect(response.body).to include('Alex Lender')
    end

    it 'renders instead of erroring when a value targets an attachment-backed field' do
      template = create(:template, account:, author:, submitter_count: 2)
      other_party_uuid = template.submitters.last['uuid']
      other_party_fields = template.fields.select { |f| f['submitter_uuid'] == other_party_uuid }
      image_field = other_party_fields.find { |f| f['type'] == 'image' }
      signature_field = other_party_fields.find { |f| f['type'] == 'signature' }
      stamp_field = template.fields.find { |f| f['type'] == 'stamp' }
      text_field = other_party_fields.find { |f| f['type'] == 'text' }

      body = create_preview_session(
        template_id: template.id,
        embed_origin: 'https://crm.example.com',
        values: {
          image_field['uuid'] => 'not-an-attachment-uuid',
          signature_field['uuid'] => 'not-an-attachment-uuid',
          stamp_field['uuid'] => 'not-an-attachment-uuid',
          text_field['uuid'] => 'Alex Lender',
          'no-such-field-uuid' => 'ignored'
        }
      )

      get URI.parse(body['preview_src']).path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Alex Lender')
      expect(response.body).not_to include('not-an-attachment-uuid')
      expect(response.body).not_to include('no-such-field-uuid')
    end

    it 'accepts a dummy value addressed by field name as well as by uuid' do
      template = create(:template, account:, author:, submitter_count: 2, only_field_types: %w[text])

      body = create_preview_session(
        template_id: template.id,
        embed_origin: 'https://crm.example.com',
        values: { 'First Name' => 'Jamie Borrower' }
      )

      get URI.parse(body['preview_src']).path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML({ template.fields.first['uuid'] => 'Jamie Borrower' }.to_json))
    end

    it 'escapes hostile dummy values instead of emitting them as markup' do
      template = create(:template, account:, author:, submitter_count: 2, only_field_types: %w[text])
      other_party_field = template.fields.last
      hostile = %(</field-value>"><script>alert('xss')</script>)

      body = create_preview_session(
        template_id: template.id,
        embed_origin: 'https://crm.example.com',
        values: { other_party_field['uuid'] => hostile }
      )

      get URI.parse(body['preview_src']).path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('<script>alert(')
      expect(response.body).to include(CGI.escapeHTML(hostile))
    end

    # A preview viewer is a guest of the paired app with no session here, so the
    # page must not carry any configured destination for the form to navigate to.
    it 'strips the configured completed redirect, completed button and policy links' do
      template = create(:template, account:, author:)
      template.update!(preferences: { 'completed_redirect_url' => 'https://fork.example.com/after-signing',
                                      'completed_message' => { 'title' => 'Go here',
                                                               'body' => 'https://fork.example.com/next' } })
      account.account_configs.create!(key: AccountConfig::FORM_COMPLETED_BUTTON_KEY,
                                      value: { 'title' => 'Back to portal',
                                               'url' => 'https://fork.example.com/portal' })
      account.account_configs.create!(key: AccountConfig::POLICY_LINKS_KEY,
                                      value: '[Terms](https://fork.example.com/terms)')

      body = create_preview_session(template_id: template.id, embed_origin: 'https://crm.example.com')

      get URI.parse(body['preview_src']).path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-completed-redirect-url=""')
      expect(response.body).not_to include('fork.example.com')
      expect(response.body).to include('data-completed-button="{}"')
      expect(template.reload.preferences['completed_redirect_url']).to eq('https://fork.example.com/after-signing')
    end

    it 'allows framing only for the origin the preview session was minted for' do
      template = create(:template, account:, author:)

      body = create_preview_session(template_id: template.id, embed_origin: 'https://crm.example.com')

      get URI.parse(body['preview_src']).path

      expect(response).to have_http_status(:ok)
      expect(response.headers['X-Frame-Options']).to be_nil
      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'self' https://crm.example.com")
    end

    it 'does not render an expired preview session' do
      template = create(:template, account:, author:)

      body = create_preview_session(template_id: template.id, embed_origin: 'https://crm.example.com')
      preview_path = URI.parse(body['preview_src']).path

      travel 3.hours do
        expect { get preview_path }.to raise_error(ActionController::RoutingError)
      end
    end

    it 'does not render a tampered or unsigned preview token' do
      create(:template, account:, author:)

      expect { get '/embed/template_preview/not-a-real-token' }.to raise_error(ActionController::RoutingError)
    end

    it 'does not render a template the token does not actually belong to' do
      other_account = create(:account)
      other_author = create(:user, account: other_account)
      other_template = create(:template, account: other_account, author: other_author)

      forged_token = TemplatePreviewSessions.generate_token(
        template_id: other_template.id,
        account_id: account.id,
        origin: 'https://crm.example.com',
        values: {},
        expires_in: 2.hours
      )

      expect { get "/embed/template_preview/#{forged_token}" }.to raise_error(ActionController::RoutingError)
    end
  end

  describe 'standalone plan and lifecycle boundaries' do
    let(:template) { create(:template, account:, author:) }
    let(:preview_params) { { template_id: template.id, embed_origin: 'https://crm.example.com' } }

    it 'keeps internal integrations usable without a subscription or human login' do
      expect(account.account_subscription).to be_nil
      body = create_preview_session(preview_params)
      expect(response).to have_http_status(:ok)
      get URI.parse(body['preview_src']).path
      expect(response).to have_http_status(:ok)
    end

    it 'refuses free customers over both the API token and browser session' do
      account.update!(account_kind: Account::CUSTOMER_KIND)
      create_preview_session(preview_params)
      expect(response).to have_http_status(:forbidden)
      sign_in(author)
      post '/api/template_preview_sessions', params: preview_params.to_json
      expect(response).to have_http_status(:forbidden)
    end

    it 'revokes a preview and its PDF link after a paid customer downgrades' do
      account.update!(account_kind: Account::CUSTOMER_KIND)
      subscription = create(:account_subscription, account:, access_state: 'active')
      body = create_preview_session(preview_params)
      expect(response).to have_http_status(:ok)
      path = URI.parse(body['preview_src']).path
      get "#{path}/document"
      expect(response).to have_http_status(:ok)
      subscription.update!(access_state: 'cancelled')
      get path
      expect(response).to have_http_status(:forbidden)
      get "#{path}/document"
      expect(response).to have_http_status(:forbidden)
    end

    %i[archived_at suspended_at].each do |state|
      it "revokes the preview and its PDF link when #{state} is set" do
        body = create_preview_session(preview_params)
        path = URI.parse(body['preview_src']).path
        get "#{path}/document"
        expect(response).to have_http_status(:ok)
        account.update!(state => Time.current)
        expect { get path }.to raise_error(ActionController::RoutingError)
        expect { get "#{path}/document" }.to raise_error(ActionController::RoutingError)
      end
    end

    it 'refuses to mint a preview for an archived template, and archiving revokes an issued one' do
      body = create_preview_session(preview_params)
      path = URI.parse(body['preview_src']).path

      template.update!(archived_at: Time.current)

      expect { get path }.to raise_error(ActionController::RoutingError)
      expect { get "#{path}/document" }.to raise_error(ActionController::RoutingError)

      create_preview_session(preview_params)
      expect(response).to have_http_status(:not_found)
    end

    it 'stops serving the same PDF URL after the preview expires' do
      body = create_preview_session(preview_params.merge(expires_in_minutes: 1))
      path = "#{URI.parse(body['preview_src']).path}/document"
      get path
      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to include('private', 'no-store')

      travel_to 2.minutes.from_now do
        expect { get path }.to raise_error(ActionController::RoutingError)
      end
    end

    it 'also serves merged PDFs without a separate public cache capability' do
      packet = create(:template, account:, author:, attachment_count: 2)
      body = create_preview_session(preview_params.merge(template_id: packet.id))

      get "#{URI.parse(body['preview_src']).path}/document"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/pdf')
      expect(response.body).to start_with('%PDF')
      expect(response.headers['Cache-Control']).to include('private', 'no-store')
      expect(response.headers['Location']).to be_nil
    end

    it 'serves the consent PDF through the preview token without a sender login' do
      body = create_preview_session(preview_params)
      path = URI.parse(body['preview_src']).path
      get path
      expect(response).to have_http_status(:ok)
      config = JSON.parse(Nokogiri::HTML(response.body).at_css('submission-form')['data-esign-consent'])
      expect(config['pdf_url']).to eq("#{path}/document")
      get config['pdf_url']
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/pdf')
      expect(response.body).to start_with('%PDF')
      expect(response.headers['Cache-Control']).to include('private', 'no-store')
      expect(response.headers['Location']).to be_nil
      expect(Submission.count).to eq(0)
      expect(Submitter.count).to eq(0)
      expect(SubmissionEvent.count).to eq(0)
    end
  end
end
