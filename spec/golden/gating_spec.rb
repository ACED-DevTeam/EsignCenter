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
  end

  describe 'MCP tokens' do
    def mcp_tools_list(account)
      mcp_token = admin_for(account).mcp_tokens.create!(name: 'Golden')
      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)

      post '/mcp', headers: { 'Authorization' => "Bearer #{mcp_token.token}", 'Content-Type' => 'application/json' },
                   params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json
    end

    it 'refuses a free MCP token and answers internal and paid ones' do
      mcp_tools_list(free_account)

      expect_json_refusal

      mcp_tools_list(internal_account)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('result', 'tools')).to be_present

      mcp_tools_list(paid_account)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('result', 'tools')).to be_present
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

    it 'refuses a field with a formula for everyone, internal included (hidden for everyone)' do
      [free_account, internal_account, paid_account].each do |account|
        template = save_fields(account, 'preferences' => { 'formula' => '{{a}} + {{b}}' })

        expect_json_refusal
        expect(template.fields.last.dig('preferences', 'formula')).to be_nil, account.account_kind
      end
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

      expect_json_refusal
    end
  end

  describe 'automatic reminders' do
    def save_reminders(account)
      end_session
      sign_in(admin_for(account))
      post '/settings/notifications', params: { account_config: { key: AccountConfig::SUBMITTER_REMINDERS,
                                                                  value: { first_duration: 'two_days' } } }
    end

    def sent_submitter_for(account)
      submission = create(:submission, :with_submitters, template: template_for(account),
                                                         created_by_user: admin_for(account))
      submission.submitters.first.tap { |submitter| submitter.update!(sent_at: Time.current) }
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

    it 'always lets a free account clear a value it can no longer set' do
      create(:account_config, account: free_account, key: AccountConfig::BCC_EMAILS, value: 'old@example.com')

      end_session
      sign_in(admin_for(free_account))
      post '/settings/notifications', params: { account_config: { key: AccountConfig::BCC_EMAILS, value: '' } }

      expect(flash[:alert]).to be_nil
      expect(free_account.account_configs.find_by(key: AccountConfig::BCC_EMAILS)).to be_nil
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
