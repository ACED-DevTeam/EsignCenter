# frozen_string_literal: true

# One example per paid-only row of the entitlement matrix
# (plans/esigncenter-standalone/spec.md, D45). Each row is proven three ways at
# the server: a free customer account is refused (status AND nothing persisted
# or enqueued), an internal account succeeds, and a paid customer succeeds.
#
# Session 5 Done-when: swap Plans.key_for to the real plan model and re-run
# this file unmodified. The only thing here that says "paid" is the account
# factory's :paid trait — Session 5 re-points that trait, not this file.
#
# delivery_tracking is a declared paid-only row whose enforcement lands with
# the EmailEvent projection in Session 8; its assertion is owed there.
RSpec.describe 'Feature gating', type: :request do
  # Eager, so account setup (the paid stub row included) never lands inside a
  # `change(AccountConfig, :count)` block.
  let!(:free_account) { create(:account) }
  let!(:paid_account) { create(:account, :paid) }
  let!(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }
  let(:json_refusal) { { 'error' => 'This feature requires a paid plan' } }
  let(:html_refusal) { I18n.t('this_feature_requires_a_paid_plan') }
  # Hidden features are on no plan, so their refusal never promises an upgrade.
  let(:json_unavailable) { { 'error' => 'This feature is not available' } }
  let(:html_unavailable) { I18n.t('this_feature_is_not_available') }
  let(:json_headers) { { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' } }

  def admin_for(account)
    admins[account.id] ||= create(:user, account:)
  end

  def token_headers(account)
    { 'x-auth-token': admin_for(account).access_token.token }
  end

  def template_for(account)
    create(:template, account:, author: admin_for(account))
  end

  def sent_submitter_for(account, template: template_for(account))
    submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))
    submission.submitters.first.tap { |submitter| submitter.update!(sent_at: Time.current) }
  end

  # A template that already carries a condition (built while the account was
  # paid, or before the matrix existed): written straight to the row, the way
  # legacy data sits there, never through the gated save.
  def conditional_template_for(account)
    template = template_for(account)
    fields = template.fields.deep_dup
    fields.last['conditions'] = [{ 'field_uuid' => fields.first['uuid'], 'action' => 'not_empty' }]
    template.update!(fields:)

    template
  end

  def formula_template_for(account)
    template = template_for(account)
    fields = template.fields.deep_dup
    fields.last['preferences'] = { 'formula' => "{{#{fields.first['uuid']}}} + 1" }
    template.update!(fields:)

    template
  end

  def put_template_fields(account, template, fields, schema: template.schema)
    end_session
    # The builder posts a JSON body with no Accept header; the refusal must
    # still come back as JSON, not as a redirect the JS would swallow.
    sign_in(admin_for(account))
    put "/templates/#{template.id}",
        params: { template: { fields:, schema:, submitters: template.submitters } }.to_json,
        headers: { 'CONTENT_TYPE' => 'application/json' }

    template.reload
  end

  def html_submission_params(template, extra = {})
    { submission: { '1' => { submitters: [{ uuid: template.submitters.first['uuid'], email: 'signer@example.com' }] } },
      send_email: '1' }.merge(extra)
  end

  def api_submission_params(template, extra = {})
    { template_id: template.id,
      submitters: [{ role: template.submitters.first['name'], email: 'signer@example.com' }] }.merge(extra)
  end

  # Devise's integration sign_out queues a Warden logout for the next request
  # but the rack-test cookie keeps authenticating the previous user in this
  # app (pretender's impersonation layer); a fresh integration session is the
  # only reliable actor switch, and it also drops the previous redirect's
  # flash. Called BEFORE an actor's request, never after (reset! clears the
  # response the example still wants to inspect).
  def end_session
    sign_out(:user)
    reset!
  end

  def expect_json_refusal
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq(json_refusal)
  end

  def expect_html_refusal
    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to eq(html_refusal)
  end

  def expect_json_unavailable
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq(json_unavailable)
  end

  def expect_html_unavailable
    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to eq(html_unavailable)
  end

  describe 'REST API tokens' do
    it 'refuses a free token, serves internal and paid tokens, and keeps the session path open' do
      template_for(free_account)

      get '/api/templates', headers: token_headers(free_account)

      expect_json_refusal

      get '/api/templates', headers: token_headers(internal_account)

      expect(response).to have_http_status(:ok)

      get '/api/templates', headers: token_headers(paid_account)

      expect(response).to have_http_status(:ok)

      # The in-app builder and dashboard call /api/* with the browser session;
      # the refusal is about tokens, never about the same endpoint over a session.
      end_session
      sign_in(admin_for(free_account))
      get '/api/templates'

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data']).to be_present
    end

    it 'refuses a mutating call from a free token before anything is created, and creates for internal' do
      expect do
        post '/api/submissions', headers: token_headers(free_account).merge(json_headers),
                                 params: api_submission_params(template_for(free_account)).to_json
      end.not_to change(Submission, :count)
      expect_json_refusal

      expect do
        post '/api/submissions', headers: token_headers(internal_account).merge(json_headers),
                                 params: api_submission_params(template_for(internal_account)).to_json
      end.to change(Submission, :count).by(1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'MCP tokens' do
    def mcp_request(account, method, params = nil)
      mcp_token = admin_for(account).mcp_tokens.create!(name: 'Golden')
      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)

      post '/mcp', headers: { 'Authorization' => "Bearer #{mcp_token.token}", 'Content-Type' => 'application/json' },
                   params: { jsonrpc: '2.0', id: 1, method:, params: }.compact.to_json
    end

    it 'refuses a free MCP token and answers internal and paid ones' do
      mcp_request(free_account, 'tools/list')

      expect_json_refusal

      mcp_request(internal_account, 'tools/list')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('result', 'tools')).to be_present

      mcp_request(paid_account, 'tools/list')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('result', 'tools')).to be_present
    end

    it 'refuses a mutating tool call from a free token before any record exists, and creates for internal' do
      call = { name: 'create_template', arguments: { name: 'Golden MCP template' } }

      expect { mcp_request(free_account, 'tools/call', call) }.not_to change(Template, :count)
      expect_json_refusal

      expect { mcp_request(internal_account, 'tools/call', call) }.to change(Template, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(Template.last).to have_attributes(account_id: internal_account.id, name: 'Golden MCP template')
    end
  end

  describe 'webhooks' do
    def save_webhook(account)
      end_session
      sign_in(admin_for(account))
      post '/settings/webhooks', params: { webhook_url: { url: 'https://hooks.example.com/esign',
                                                          events: ['template.updated'] } }
    end

    it 'refuses saving and test-sending for a free account, saves for internal and paid, and enqueues nothing ' \
       'for a free account with a pre-existing URL' do
      expect { save_webhook(free_account) }.not_to change(WebhookUrl, :count)
      expect_html_refusal

      expect { save_webhook(internal_account) }.to change(WebhookUrl, :count).by(1)
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_nil

      expect { save_webhook(paid_account) }.to change(WebhookUrl, :count).by(1)
      expect(flash[:alert]).to be_nil

      # A URL saved before a downgrade stays (D43) but receives nothing.
      stale_webhook = create(:webhook_url, account: free_account, events: ['template.updated'])
      paid_webhook = paid_account.webhook_urls.sole

      expect(WebhookUrls.for_account_id(free_account.id, 'template.updated')).to be_empty
      expect(WebhookUrls.for_account_id(paid_account.id, 'template.updated')).to contain_exactly(paid_webhook)

      expect { WebhookUrls.enqueue_events(template_for(free_account), 'template.updated') }
        .not_to change(SendTemplateUpdatedWebhookRequestJob.jobs, :size)
      expect { WebhookUrls.enqueue_events(template_for(paid_account), 'template.updated') }
        .to change(SendTemplateUpdatedWebhookRequestJob.jobs, :size).by(1)

      end_session
      sign_in(admin_for(free_account))

      expect { post "/settings/webhooks/#{stale_webhook.id}/resend" }
        .not_to change(SendTestWebhookRequestJob.jobs, :size)
      expect_html_refusal
    end

    it 'refuses a free account changing a URL\'s events or secret header (rows unchanged), keeps viewing and ' \
       'deleting open, and lets an internal account write both' do
      free_webhook = create(:webhook_url, account: free_account, events: ['form.completed'])
      internal_webhook = create(:webhook_url, account: internal_account, events: ['form.completed'])
      events = { webhook_url: { events: { 'form.viewed' => '1' } } }
      secret = { webhook_url: { secret: { key: 'X-Key', value: 'value' } } }

      end_session
      sign_in(admin_for(free_account))

      put "/webhook_preferences/#{free_webhook.id}", params: events

      expect_html_refusal
      expect(free_webhook.reload.events).to eq(['form.completed'])

      put "/webhook_secret/#{free_webhook.id}", params: secret

      expect_html_refusal
      expect(free_webhook.reload.secret).to eq({})

      # Reads and cleanup never need the entitlement.
      get "/webhook_secret/#{free_webhook.id}"

      expect(response).to have_http_status(:ok)
      expect { delete "/settings/webhooks/#{free_webhook.id}" }.to change(WebhookUrl, :count).by(-1)

      end_session
      sign_in(admin_for(internal_account))

      put "/webhook_preferences/#{internal_webhook.id}", params: events

      expect(response).to have_http_status(:ok)
      expect(internal_webhook.reload.events).to contain_exactly('form.completed', 'form.viewed')

      put "/webhook_secret/#{internal_webhook.id}", params: secret

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_nil
      expect(internal_webhook.reload.secret).to eq('X-Key' => 'value')
    end
  end

  describe 'signing sessions' do
    def create_signing_session(account, headers)
      template = template_for(account)

      post '/api/signing_sessions', headers: headers.merge(json_headers), params: {
        template_id: template.id,
        embed_origin: 'https://app.example.com',
        submitters: [{ role: template.submitters.first['name'], email: 'signer@example.com' }]
      }.to_json
    end

    it 'refuses a free account by token and by session, and creates for internal and paid' do
      expect { create_signing_session(free_account, token_headers(free_account)) }.not_to change(Submission, :count)
      expect_json_refusal

      # Named refusal: the same call over a browser session is not covered by
      # the generic token refusal, so this proves the signing-session row itself.
      end_session
      sign_in(admin_for(free_account))

      expect { create_signing_session(free_account, {}) }.not_to change(Submission, :count)
      expect_json_refusal

      end_session

      expect { create_signing_session(internal_account, token_headers(internal_account)) }
        .to change(Submission, :count).by(1)
      expect(response).to have_http_status(:ok)

      expect { create_signing_session(paid_account, token_headers(paid_account)) }.to change(Submission, :count).by(1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'embedded template builder' do
    def create_builder_session(account, headers)
      template = template_for(account)

      post '/api/template_builder_sessions', headers: headers.merge(json_headers), params: {
        template_id: template.id, embed_origin: 'https://crm.example.com'
      }.to_json

      template
    end

    it 'refuses a free account by token and by session, and opens a builder for internal and paid' do
      template = create_builder_session(free_account, token_headers(free_account))

      expect_json_refusal
      expect(template.reload.preferences['embed_builder']).to be_nil

      end_session
      sign_in(admin_for(free_account))
      template = create_builder_session(free_account, {})

      expect_json_refusal
      expect(template.reload.preferences['embed_builder']).to be_nil

      end_session

      template = create_builder_session(internal_account, token_headers(internal_account))

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['builder_src']).to be_present
      expect(template.reload.preferences.dig('embed_builder', 'origin')).to eq('https://crm.example.com')

      create_builder_session(paid_account, token_headers(paid_account))

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['builder_src']).to be_present
    end

    # D43 keeps in-flight SIGNING entitled, not an open builder: the embed row
    # is checked on every builder-token request, so a token minted while paid
    # (valid for up to 24 h) stops working the moment the account is downgraded.
    it 'refuses a builder token minted while paid once the account is downgraded, without touching the template' do
      template = create_builder_session(paid_account, token_headers(paid_account))
      token = URI.parse(response.parsed_body['builder_src']).path.split('/').last
      payload = { template: { name: 'Renamed after downgrade', schema: template.schema,
                              submitters: template.submitters, fields: template.fields, variables_schema: {} } }

      get "/embed/template_builder/#{token}"

      expect(response).to have_http_status(:ok)
      expect(response.headers['X-Frame-Options']).to be_nil
      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'self' https://crm.example.com")

      downgrade_to_free!(paid_account)

      get "/embed/template_builder/#{token}"

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include(html_refusal)
      # The refusal is shown inside the customer's iframe, so it carries the
      # same frame headers as the builder it replaces — otherwise the browser
      # blanks the frame and the customer never sees why.
      expect(response.headers['X-Frame-Options']).to be_nil
      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'self' https://crm.example.com")

      put "/embed/template_builder/#{token}/templates/#{template.id}",
          params: payload.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }

      expect_json_refusal
      expect(template.reload.name).not_to eq('Renamed after downgrade')

      get "/embed/template_builder/#{token}/templates/#{template.id}/documents"

      expect_json_refusal
    end
  end

  describe 'conditional logic and formulas (builder save)' do
    def save_fields(account, field_patch)
      template = template_for(account)
      fields = template.fields.deep_dup
      fields.last.merge!(field_patch.deep_stringify_keys)

      end_session
      # The builder posts a JSON body with no Accept header; the refusal must
      # still come back as JSON, not as a redirect the JS would swallow.
      sign_in(admin_for(account))
      put "/templates/#{template.id}",
          params: { template: { fields:, schema: template.schema, submitters: template.submitters } }.to_json,
          headers: { 'CONTENT_TYPE' => 'application/json' }

      template.reload
    end

    let(:condition) do
      { 'conditions' => [{ 'field_uuid' => SecureRandom.uuid, 'action' => 'not_empty' }] }
    end

    it 'refuses a field with conditions for a free account and saves it for internal and paid' do
      template = save_fields(free_account, condition)

      expect_json_refusal
      expect(template.fields.last['conditions']).to be_nil

      template = save_fields(internal_account, condition)

      expect(response).to have_http_status(:ok)
      expect(template.fields.last['conditions']).to be_present

      template = save_fields(paid_account, condition)

      expect(response).to have_http_status(:ok)
      expect(template.fields.last['conditions']).to be_present
    end

    it 'refuses a field with a formula for everyone, internal included (hidden for everyone), and never says ' \
       '"paid plan" for it' do
      [free_account, internal_account, paid_account].each do |account|
        template = save_fields(account, 'preferences' => { 'formula' => '{{a}} + {{b}}' })

        expect_json_unavailable
        expect(template.fields.last.dig('preferences', 'formula')).to be_nil, account.account_kind
      end
    end

    it 'lets a downgraded account keep saving a template that already carries conditions, refuses only a ' \
       'condition the save introduces, and always allows removing one' do
      template = conditional_template_for(free_account)
      legacy_conditions = template.fields.last['conditions']

      # Rename a field, leave the legacy condition untouched: a routine save.
      fields = template.fields.deep_dup
      fields.first['name'] = 'Renamed'
      template = put_template_fields(free_account, template, fields)

      expect(response).to have_http_status(:ok)
      expect(template.fields.first['name']).to eq('Renamed')
      expect(template.fields.last['conditions']).to eq(legacy_conditions)

      # A second field gaining a condition is new conditional logic.
      fields = template.fields.deep_dup
      fields[1]['conditions'] = [{ 'field_uuid' => fields.first['uuid'], 'action' => 'not_empty' }]
      template = put_template_fields(free_account, template, fields)

      expect_json_refusal
      expect(template.fields[1]['conditions']).to be_nil
      expect(template.fields.last['conditions']).to eq(legacy_conditions)

      # Editing the legacy condition's content is new logic too.
      fields = template.fields.deep_dup
      fields.last['conditions'] = [{ 'field_uuid' => fields.first['uuid'], 'action' => 'empty' }]
      template = put_template_fields(free_account, template, fields)

      expect_json_refusal
      expect(template.fields.last['conditions']).to eq(legacy_conditions)

      # Removing it never needs the entitlement.
      fields = template.fields.deep_dup
      fields.last.delete('conditions')
      template = put_template_fields(free_account, template, fields)

      expect(response).to have_http_status(:ok)
      expect(template.fields.last['conditions']).to be_nil
    end

    it 'keeps evaluating a downgraded account\'s existing conditions at signing time (D43: in-flight signing ' \
       'keeps its entitlements)' do
      template = conditional_template_for(free_account)
      gate_uuid = template.fields.first['uuid']
      schema = template.schema.deep_dup
      schema.first['conditions'] = [{ 'field_uuid' => gate_uuid, 'action' => 'not_empty' }]
      template.update!(schema:)

      submitter = sent_submitter_for(free_account, template:)
      submission = submitter.submission

      # The gating field is empty: the conditional document is hidden and the
      # conditional field reaches the signer with its conditions for evaluation.
      expect(Submissions.filtered_conditions_schema(submission)).to be_empty
      conditional_field = Submissions.filtered_conditions_fields(submitter).find { |f| f['conditions'].present? }

      expect(conditional_field['uuid']).to eq(template.fields.last['uuid'])

      submitter.update!(values: { gate_uuid => 'filled' })

      expect(Submissions.filtered_conditions_schema(submission.reload).pluck('attachment_uuid'))
        .to eq(template.schema.pluck('attachment_uuid'))
    end

    it 'treats a clone as a new template: a free account cannot clone its conditional template (the original ' \
       'stays usable) and nobody, internal included, can clone a template with a formula field' do
      conditional_template = conditional_template_for(free_account)

      end_session
      sign_in(admin_for(free_account))

      expect do
        post "/templates/#{conditional_template.id}/clone", params: { template: { name: 'Copy' } }
      end.not_to change(Template, :count)
      expect_html_refusal
      expect(conditional_template.reload.fields.last['conditions']).to be_present

      # The same template still opens and saves for its owner.
      get "/templates/#{conditional_template.id}/edit"

      expect(response).to have_http_status(:ok)

      formula_template = formula_template_for(internal_account)

      end_session
      sign_in(admin_for(internal_account))

      expect do
        post "/templates/#{formula_template.id}/clone", params: { template: { name: 'Copy' } }
      end.not_to change(Template, :count)
      expect_html_unavailable

      expect do
        post "/api/templates/#{formula_template.id}/clone", params: { name: 'Copy' }.to_json,
                                                            headers: token_headers(internal_account).merge(json_headers)
      end.not_to change(Template, :count)
      expect_json_unavailable

      # A plain template clones for everyone.
      plain_template = template_for(internal_account)

      expect do
        post "/templates/#{plain_template.id}/clone", params: { template: { name: 'Copy' } }
      end.to change(Template, :count).by(1)
    end

    it 'applies the same check to per-submission field overrides (fields[].preferences.formula, conditions)' do
      template = template_for(internal_account)
      field_name = template.fields.first['name']
      formula_params = api_submission_params(template)
      formula_params[:submitters].first[:fields] = [{ name: field_name, preferences: { formula: '1+1' } }]

      expect do
        post '/api/submissions', headers: token_headers(internal_account).merge(json_headers),
                                 params: formula_params.to_json
      end.not_to change(Submission, :count)
      expect_json_unavailable

      # Conditions on a per-submission field are conditional logic: paid-only.
      # The API permit lists drop `conditions`, so this is proven at the seam
      # every door funnels through (Submissions::CreateFromSubmitters).
      free_template = template_for(free_account)
      conditions_attrs = [{ submitters: [{ role: free_template.submitters.first['name'], email: 'signer@example.com',
                                           fields: [{ name: field_name,
                                                      conditions: [{ field_uuid: SecureRandom.uuid,
                                                                     action: 'not_empty' }] }] }] }]

      expect do
        Submissions.create_from_submitters(template: free_template, user: admin_for(free_account), source: :api,
                                           submitters_order: 'preserved',
                                           submissions_attrs: conditions_attrs.map(&:with_indifferent_access))
      end.to raise_error(Entitlements::UpgradeRequired) { |error| expect(error.feature).to eq(:conditional_logic) }
      expect(Submission.count).to eq(0)

      plain_params = api_submission_params(template)
      plain_params[:submitters].first[:fields] = [{ name: field_name, default_value: 'Prefilled' }]

      expect do
        post '/api/submissions', headers: token_headers(internal_account).merge(json_headers),
                                 params: plain_params.to_json
      end.to change(Submission, :count).by(1)
      expect(response).to have_http_status(:ok)
    end

    it 'applies the same check to templates created over the API with fields' do
      pdf = Base64.encode64(Rails.root.join('spec/fixtures/sample-document.pdf').read)
      field = { name: 'Total', type: 'text', preferences: { formula: '{{a}} + {{b}}' },
                areas: [{ x: 0.1, y: 0.1, w: 0.2, h: 0.05, page: 0, document: 0 }] }

      expect do
        post '/api/templates', headers: token_headers(internal_account).merge(json_headers),
                               params: { name: 'Formula', documents: [{ name: 'doc.pdf', file: pdf }],
                                         fields: [field] }.to_json
      end.not_to change(Template, :count)

      expect_json_unavailable
    end
  end

  describe 'automatic reminders' do
    def save_reminders(account)
      end_session
      sign_in(admin_for(account))
      post '/settings/notifications', params: { account_config: { key: AccountConfig::SUBMITTER_REMINDERS,
                                                                  value: { first_duration: 'two_days' } } }
    end

    it 'refuses the reminders setting for a free account, saves it for internal and paid, and schedules ' \
       'nothing for a free account that still carries a reminders row' do
      expect { save_reminders(free_account) }.not_to change(AccountConfig, :count)
      expect_html_refusal

      expect { save_reminders(internal_account) }.to change(AccountConfig, :count).by(1)
      expect(flash[:alert]).to be_nil

      expect { save_reminders(paid_account) }.to change(AccountConfig, :count).by(1)
      expect(flash[:alert]).to be_nil

      create(:account_config, account: free_account, key: AccountConfig::SUBMITTER_REMINDERS,
                              value: { 'first_duration' => 'two_days' })

      expect { Submitters::ScheduleReminders.call(sent_submitter_for(free_account)) }
        .not_to change(SendSubmitterInvitationReminderEmailJob.jobs, :size)
      expect { Submitters::ScheduleReminders.call(sent_submitter_for(paid_account)) }
        .to change(SendSubmitterInvitationReminderEmailJob.jobs, :size).by(1)
    end
  end

  describe 'branding removal' do
    def save_remove_branding(account)
      end_session
      sign_in(admin_for(account))
      post '/settings/personalization', params: { account_config: { key: AccountConfig::REMOVE_BRANDING_KEY,
                                                                    value: 'true' } }
    end

    def remove_branding_flag(account)
      account.account_configs.find_by(key: AccountConfig::REMOVE_BRANDING_KEY)&.value
    end

    def invitation_html(account)
      submission = create(:submission, :with_submitters, template: template_for(account),
                                                         created_by_user: admin_for(account))
      mail = SubmitterMailer.invitation_email(submission.submitters.first)

      [submission.submitters.first, (mail.html_part || mail).body.decoded]
    end

    it 'refuses the flag for a free account and saves it for internal and paid' do
      save_remove_branding(free_account)

      expect_html_refusal
      expect(remove_branding_flag(free_account)).to be_nil

      save_remove_branding(internal_account)

      expect(flash[:alert]).to be_nil
      expect(remove_branding_flag(internal_account)).to be(true)

      save_remove_branding(paid_account)

      expect(flash[:alert]).to be_nil
      expect(remove_branding_flag(paid_account)).to be(true)
    end

    it 'drops only the wording: a paid account with the flag sends no "Sent using" line and shows no ' \
       '"Powered by", while the DocuSeal attribution still renders; a free account with the flag keeps both' do
      create(:account_config, account: paid_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)
      create(:account_config, account: free_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      expect(Accounts.branding_removed?(paid_account)).to be(true)
      expect(Accounts.branding_removed?(free_account)).to be(false)

      paid_submitter, paid_html = invitation_html(paid_account)

      expect(paid_html).not_to include('Sent using')

      get "/s/#{paid_submitter.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('powered_by'))
      expect(response.body).to include("href=\"#{Docuseal::DOCUSEAL_URL}/start\"")
      expect(response.body).to include('>DocuSeal</a>')

      free_submitter, free_html = invitation_html(free_account)

      expect(free_html).to include('Sent using')

      get "/s/#{free_submitter.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('powered_by'))
      expect(response.body).to include("href=\"#{Docuseal::DOCUSEAL_URL}/start\"")
    end

    it 'honours the flag in every mailer and page: the verification-code email and the embedded builder page' do
      create(:account_config, account: paid_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)
      create(:account_config, account: free_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      paid_submitter = sent_submitter_for(paid_account).tap { |s| s.update!(email: 'paid@example.com') }
      free_submitter = sent_submitter_for(free_account).tap { |s| s.update!(email: 'free@example.com') }

      paid_otp = SubmitterMailer.otp_verification_email(paid_submitter)
      free_otp = SubmitterMailer.otp_verification_email(free_submitter)

      expect((paid_otp.html_part || paid_otp).body.decoded).not_to include('Sent using')
      expect((free_otp.html_part || free_otp).body.decoded).to include('Sent using')

      smtp_mail = SettingsMailer.smtp_successful_setup('admin@example.com', paid_account)

      expect((smtp_mail.html_part || smtp_mail).body.decoded).not_to include('Sent using')

      # The embedded builder is itself paid-only, so the page is opened as the
      # paid account and then read again after a downgrade: the flag goes inert.
      post '/api/template_builder_sessions', headers: token_headers(paid_account).merge(json_headers),
                                             params: { template_id: template_for(paid_account).id,
                                                       embed_origin: 'https://crm.example.com' }.to_json

      expect(response).to have_http_status(:ok)

      builder_path = URI.parse(response.parsed_body['builder_src']).path

      get builder_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('powered_by'))
      expect(response.body).to include("href=\"#{Docuseal::DOCUSEAL_URL}\"")
      expect(response.body).to include('>DocuSeal</a>')

      # After the downgrade the builder token is refused (the embed row is
      # re-checked on every request); the refusal page still carries the
      # attribution, and the branding flag has gone inert with the plan.
      downgrade_to_free!(paid_account)
      get builder_path

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include(I18n.t('powered_by'))
      expect(response.body).to include("href=\"#{Docuseal::DOCUSEAL_URL}\"")
      expect(response.body).to include('>DocuSeal</a>')
    end
  end

  describe 'custom email templates' do
    def save_invitation_email(account)
      end_session
      sign_in(admin_for(account))
      post '/settings/personalization', params: { account_config: { key: AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                                                                    value: { subject: 'Please sign {{template.name}}',
                                                                             body: 'Hello {{submitter.link}}' } } }
    end

    def save_template_email_copy(account)
      template = template_for(account)

      end_session
      sign_in(admin_for(account))
      post "/templates/#{template.id}/preferences",
           params: { template: { preferences: { request_email_subject: 'Custom subject' } } }

      template.reload
    end

    it 'refuses the account email template and the per-template copy for a free account, saves both for ' \
       'internal and paid' do
      expect { save_invitation_email(free_account) }.not_to change(AccountConfig, :count)
      expect_html_refusal

      expect { save_invitation_email(internal_account) }.to change(AccountConfig, :count).by(1)
      expect(flash[:alert]).to be_nil

      expect { save_invitation_email(paid_account) }.to change(AccountConfig, :count).by(1)
      expect(flash[:alert]).to be_nil

      template = save_template_email_copy(free_account)

      expect_html_refusal
      expect(template.preferences['request_email_subject']).to be_nil

      template = save_template_email_copy(internal_account)

      expect(response).to have_http_status(:ok)
      expect(template.preferences['request_email_subject']).to eq('Custom subject')

      template = save_template_email_copy(paid_account)

      expect(response).to have_http_status(:ok)
      expect(template.preferences['request_email_subject']).to eq('Custom subject')
    end

    it 'refuses the send dialog\'s "save this message to the template" for a free account before anything ' \
       'persists, and saves it for internal' do
      free_template = template_for(free_account)
      params = html_submission_params(free_template, save_message: '1', is_custom_message: '1',
                                                     subject: 'Dialog subject', body: 'Dialog body')

      end_session
      sign_in(admin_for(free_account))

      expect do
        post "/templates/#{free_template.id}/submissions", params:
      end.not_to(change { [Submission.count, EmailMessage.count] })
      expect_html_refusal
      expect(free_template.reload.preferences.slice('request_email_subject', 'request_email_body')).to be_empty

      internal_template = template_for(internal_account)

      end_session
      sign_in(admin_for(internal_account))

      expect do
        post "/templates/#{internal_template.id}/submissions",
             params: html_submission_params(internal_template, save_message: '1', is_custom_message: '1',
                                                               subject: 'Dialog subject', body: 'Dialog body')
      end.to change(Submission, :count).by(1)
      expect(flash[:alert]).to be_nil
      expect(internal_template.reload.preferences).to include('request_email_subject' => 'Dialog subject',
                                                              'request_email_body' => 'Dialog body')
    end
  end

  describe 'per-account SMTP' do
    def save_smtp(account)
      end_session
      sign_in(admin_for(account))
      post '/settings/email', params: { encrypted_config: { value: { host: 'smtp.example.com', port: '587',
                                                                     username: 'mailer', password: 'secret',
                                                                     from_email: 'docs@example.com',
                                                                     authentication: 'plain', security: 'tls' } } }
    end

    it 'refuses a free account without an EncryptedConfig row and saves for internal and paid' do
      expect { save_smtp(free_account) }.not_to change(EncryptedConfig, :count)
      expect_html_refusal

      expect { save_smtp(internal_account) }.to change(EncryptedConfig, :count).by(1)
      expect(flash[:alert]).to be_nil

      expect { save_smtp(paid_account) }.to change(EncryptedConfig, :count).by(1)
      expect(flash[:alert]).to be_nil
    end
  end

  describe 'BCC / documents-copy address' do
    def save_bcc(account)
      end_session
      sign_in(admin_for(account))
      post '/settings/notifications', params: { account_config: { key: AccountConfig::BCC_EMAILS,
                                                                  value: 'archive@example.com' } }
    end

    def save_template_bcc(account)
      template = template_for(account)

      end_session
      sign_in(admin_for(account))
      post "/templates/#{template.id}/preferences",
           params: { template: { preferences: { bcc_completed: 'archive@example.com' } } }

      template.reload
    end

    it 'refuses the account BCC and the per-template BCC for a free account, saves both for internal and paid' do
      expect { save_bcc(free_account) }.not_to change(AccountConfig, :count)
      expect_html_refusal

      expect { save_bcc(internal_account) }.to change(AccountConfig, :count).by(1)
      expect(flash[:alert]).to be_nil

      expect { save_bcc(paid_account) }.to change(AccountConfig, :count).by(1)
      expect(flash[:alert]).to be_nil

      template = save_template_bcc(free_account)

      expect_html_refusal
      expect(template.preferences['bcc_completed']).to be_nil

      template = save_template_bcc(internal_account)

      expect(response).to have_http_status(:ok)
      expect(template.preferences['bcc_completed']).to eq('archive@example.com')

      template = save_template_bcc(paid_account)

      expect(response).to have_http_status(:ok)
      expect(template.preferences['bcc_completed']).to eq('archive@example.com')
    end

    it 'refuses a per-submission bcc_completed for a free account over the HTML send dialog and the session API, ' \
       'and stores it for internal' do
      free_template = template_for(free_account)

      end_session
      sign_in(admin_for(free_account))

      expect do
        post "/templates/#{free_template.id}/submissions",
             params: html_submission_params(free_template, bcc_completed: 'archive@example.com')
      end.not_to change(Submission, :count)
      expect_html_refusal

      bcc_params = api_submission_params(free_template, bcc_completed: 'archive@example.com')

      expect do
        post '/api/submissions', params: bcc_params.to_json, headers: json_headers
      end.not_to change(Submission, :count)
      expect_json_refusal

      end_session

      internal_template = template_for(internal_account)

      expect do
        post '/api/submissions', headers: token_headers(internal_account).merge(json_headers),
                                 params: api_submission_params(internal_template,
                                                               bcc_completed: 'archive@example.com').to_json
      end.to change(Submission, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(Submission.last.preferences['bcc_completed']).to eq('archive@example.com')
    end

    it 'always lets a free account clear a value it can no longer set' do
      create(:account_config, account: free_account, key: AccountConfig::BCC_EMAILS, value: 'old@example.com')

      end_session
      sign_in(admin_for(free_account))
      post '/settings/notifications', params: { account_config: { key: AccountConfig::BCC_EMAILS, value: '' } }

      expect(flash[:alert]).to be_nil
      expect(free_account.account_configs.find_by(key: AccountConfig::BCC_EMAILS)).to be_nil
    end
  end

  describe 'SMS (hidden for everyone)' do
    it 'refuses a requested SMS send over HTML and the API for free and internal accounts alike, changes nothing, ' \
       'and never says "paid plan"' do
      [free_account, internal_account].each do |account|
        submitter = sent_submitter_for(account)

        end_session
        sign_in(admin_for(account))
        put "/submitters/#{submitter.id}", params: { submitter: { phone: '+15551234567' }, send_sms: '1' }

        expect_html_unavailable
        expect(submitter.reload.phone).to be_blank, account.account_kind

        # The session path is open for every plan, so this proves the SMS row
        # itself rather than the token refusal.
        put "/api/submitters/#{submitter.id}", headers: json_headers,
                                               params: { phone: '+15551234567', send_sms: true }.to_json

        expect_json_unavailable
        expect(submitter.reload.phone).to be_blank, account.account_kind
        expect(submitter.preferences['send_sms']).to be_nil

        expect do
          post '/api/submissions', headers: json_headers,
                                   params: api_submission_params(template_for(account), send_sms: true).to_json
        end.not_to change(Submission, :count)
        expect_json_unavailable
      end
    end
  end

  # D43 read-time: what an account saved while paid stays in place after a
  # downgrade but goes inert — the row is still there, nothing reads it.
  describe 'retained paid settings after a downgrade' do
    include_context 'with isolated SMTP environment'

    def pin_smtp(account)
      create(:encrypted_config, account:, key: EncryptedConfig::EMAIL_SMTP_KEY,
                                value: { 'host' => 'pinned.smtp.example', 'port' => '587', 'username' => 'pinned',
                                         'password' => 'secret', 'from_email' => 'docs@example.com',
                                         'authentication' => 'plain' })
    end

    it 'skips a pinned SMTP server once the account is no longer paid, keeping the row' do
      pin = pin_smtp(paid_account)
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'

      expect(MailConfigs.resolve(paid_account)).to have_attributes(source: :account)
      expect(MailConfigs.resolve(paid_account).smtp[:address]).to eq('pinned.smtp.example')

      downgrade_to_free!(paid_account)

      expect(MailConfigs.resolve(paid_account)).to have_attributes(source: :env)
      expect(MailConfigs.resolve(paid_account).smtp[:address]).to eq('platform.smtp.example')
      expect(EncryptedConfig.exists?(pin.id)).to be(true)
    end

    it 'renders the default email copy once the account is no longer paid, keeping the custom copy' do
      create(:account_config, account: paid_account, key: AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                              value: { 'subject' => 'Account subject', 'body' => 'Account body {{submitter.link}}' })
      template = template_for(paid_account)
      template.update!(preferences: template.preferences.merge('request_email_subject' => 'Template subject',
                                                               'request_email_body' => 'Template body'))
      submitter = sent_submitter_for(paid_account, template:)

      mail = SubmitterMailer.invitation_email(submitter)

      expect(mail.subject).to eq('Template subject')
      expect((mail.html_part || mail).body.decoded).to include('Template body')

      downgrade_to_free!(paid_account)

      mail = SubmitterMailer.invitation_email(submitter.reload)

      expect(mail.subject).to eq(I18n.t(:you_are_invited_to_sign_a_document))
      expect((mail.html_part || mail).body.decoded).not_to include('Template body', 'Account body')
      expect(template.reload.preferences['request_email_subject']).to eq('Template subject')
      expect(paid_account.account_configs.find_by(key: AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY)).to be_present
    end

    it 'sends no BCC copy once the account is no longer paid, keeping the addresses' do
      create(:account_config, account: paid_account, key: AccountConfig::BCC_EMAILS, value: 'archive@example.com')
      template = template_for(paid_account)
      template.update!(preferences: template.preferences.merge('bcc_completed' => 'legal@example.com'))
      submission = sent_submitter_for(paid_account, template:).submission
      job = ProcessSubmitterCompletionJob.new

      expect(job.build_bcc_addresses(submission)).to eq(['legal@example.com'])

      downgrade_to_free!(paid_account)

      expect(job.build_bcc_addresses(submission.reload)).to eq([])
      expect(template.reload.preferences['bcc_completed']).to eq('legal@example.com')
      expect(paid_account.account_configs.find_by(key: AccountConfig::BCC_EMAILS)&.value).to eq('archive@example.com')
    end
  end

  describe 'plan resolution' do
    it 'resolves the operator kind to the internal plan, hides SMS from everyone, and rejects unknown features' do
      expect(Plans.key_for(create(:account, :operator))).to eq(Plans::INTERNAL)
      expect(Plans.key_for(internal_account)).to eq(Plans::INTERNAL)
      expect(Plans.key_for(paid_account)).to eq(Plans::PAID)
      expect(Plans.key_for(free_account)).to eq(Plans::FREE)

      expect(Entitlements.allowed?(internal_account, :sms)).to be(false)
      expect(Entitlements.allowed?(create(:account, :operator), :formulas)).to be(false)

      expect { Entitlements.allowed?(internal_account, :not_a_feature) }.to raise_error(ArgumentError)
    end

    it 'grants :use abilities for every paid-only row to paid and internal users and none to free users' do
      Entitlements::PAID_ONLY.each do |feature|
        expect(Ability.new(admin_for(free_account)).can?(:use, feature)).to be(false), feature.to_s
        expect(Ability.new(admin_for(paid_account)).can?(:use, feature)).to be(true), feature.to_s
        internal_viewer = create(:user, :viewer, account: internal_account)

        expect(Ability.new(internal_viewer).can?(:use, feature)).to be(true), feature.to_s
      end

      Entitlements::HIDDEN.each do |feature|
        expect(Ability.new(admin_for(internal_account)).can?(:use, feature)).to be(false), feature.to_s
      end
    end
  end
end
