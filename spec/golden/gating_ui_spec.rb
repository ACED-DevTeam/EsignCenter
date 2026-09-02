# frozen_string_literal: true

# The UI face of the entitlement matrix (Session 3, Phase C): every paid-only
# settings surface shows the upgrade call-to-action to a free account and the
# real form to an internal account, and the two AGPL attribution points keep
# rendering whether or not an account has switched its branding off. The
# server-side refusals themselves are proven in spec/golden/gating_spec.rb.
RSpec.describe 'Feature gating UI', type: :request do
  let!(:free_account) { create(:account) }
  let!(:paid_account) { create(:account, :paid) }
  let!(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }
  let(:cta_text) { I18n.t('this_feature_requires_a_paid_plan') }

  def admin_for(account)
    admins[account.id] ||= create(:user, account:)
  end

  def template_for(account)
    create(:template, account:, author: admin_for(account))
  end

  # See gating_spec.rb: a fresh integration session is the only reliable actor switch.
  def visit_as(account, path)
    sign_out(:user)
    reset!
    sign_in(admin_for(account))
    get path

    expect(response).to have_http_status(:ok)

    response.body
  end

  def expect_cta(body)
    expect(body).to include(cta_text)
    expect(body).to include('data-upgrade-cta')
  end

  def expect_no_cta(body)
    expect(body).not_to include(cta_text)
    expect(body).not_to include('data-upgrade-cta')
  end

  # Each row: [description, path builder, markers of the REAL form]. A free
  # account must see the CTA and none of the markers; internal sees the
  # markers and no CTA.
  gated_pages = {
    'API settings' => [->(_) { '/settings/api' }, ['id="api_key"', 'X-Auth-Token']],
    'MCP settings' => [->(_) { '/settings/mcp' }, ['/settings/mcp/new', 'name="account_config[value]"']],
    'Webhook settings' => [->(_) { '/settings/webhooks' }, ['name="webhook_url[url]"']],
    'Email SMTP settings' => [->(_) { '/settings/email' }, ['name="encrypted_config[value][host]"']],
    'Notifications settings (BCC + reminders)' => [
      ->(_) { '/settings/notifications' },
      ['name="account_config[value][first_duration]"', 'type="email" multiple="multiple" name="account_config[value]"']
    ],
    'Personalization (email templates + branding)' => [
      ->(_) { '/settings/personalization' },
      ['name="account_config[value][subject]"', "value=\"#{AccountConfig::REMOVE_BRANDING_KEY}\""]
    ],
    'Template code modal (embed)' => [->(t) { "/templates/#{t.id}/code_modal" }, ['id="embedding_url"']],
    'Template preferences API tab (embed)' => [->(t) { "/templates/#{t.id}/preferences" }, ['id="embedding_url"']],
    'Template preferences (BCC + per-template email copy)' => [
      ->(t) { "/templates/#{t.id}/preferences" },
      ['name="template[preferences][bcc_completed]"', 'id="submitter_invitation_email_template_form"',
       'name="template[preferences][documents_copy_email_subject]"',
       'name="template[preferences][completed_notification_email_subject]"',
       'form="submitter_invitation_email_template_form"', 'form="submitter_documents_copy_email_template_form"',
       'form="submitter_completed_email_template_form"']
    ]
  }

  gated_pages.each do |name, (path_for, real_form_markers)|
    it "#{name}: CTA for a free account, the real form for an internal account" do
      free_body = visit_as(free_account, path_for.call(template_for(free_account)))

      expect_cta(free_body)
      real_form_markers.each { |marker| expect(free_body).not_to include(marker), marker }

      internal_body = visit_as(internal_account, path_for.call(template_for(internal_account)))

      expect_no_cta(internal_body)
      real_form_markers.each { |marker| expect(internal_body).to include(marker), marker }
    end
  end

  it 'keeps the free surfaces on the personalization page for a free account (logo upload, signer-page copy)' do
    body = visit_as(free_account, '/settings/personalization')

    expect(body).to include('/settings/personalization_logo')
    expect(body).to include("value=\"#{AccountConfig::FORM_COMPLETED_MESSAGE_KEY}\"")
    expect(body).to include("value=\"#{AccountConfig::POLICY_LINKS_KEY}\"")
  end

  it 'keeps the free toggles on the template preferences page for a free account' do
    body = visit_as(free_account, "/templates/#{template_for(free_account).id}/preferences")

    expect(body).to include('name="template[preferences][request_email_enabled]"')
    expect(body).to include('name="template[preferences][documents_copy_email_enabled]"')
    expect(body).to include('name="template[preferences][completed_notification_email_enabled]"')
  end

  it 'keeps the "reset to default" link on the template preferences page for a downgraded account with legacy ' \
     'custom email copy (cleanup never needs the entitlement)' do
    template = template_for(paid_account)
    template.update!(preferences: template.preferences.merge('request_email_subject' => 'Legacy subject',
                                                             'request_email_body' => 'Legacy body'))
    downgrade_to_free!(paid_account)

    body = visit_as(paid_account, "/templates/#{template.id}/preferences")

    expect_cta(body)
    expect(body).not_to include('id="submitter_invitation_email_template_form"')
    expect(body).to include('id="submitter_invitation_email_reset_link"')
    expect(body).to include(I18n.t('reset_default'))
  end

  it 'send dialog offers "save as default template message" only to an entitled account' do
    free_body = visit_as(free_account, "/templates/#{template_for(free_account).id}/submissions/new")

    expect(free_body).to include('name="subject"')
    expect(free_body).not_to include('name="save_message"')

    internal_body = visit_as(internal_account, "/templates/#{template_for(internal_account).id}/submissions/new")

    expect(internal_body).to include('name="save_message"')
  end

  # SMS is hidden for everyone (no plan has it), so the send dialog offers no
  # "via Phone" recipients tab to anyone — a phone-only recipient could never
  # be reached. The e-mail tab proves the tab strip itself rendered.
  it 'send dialog offers no "via Phone" recipients tab to any account' do
    [free_account, paid_account, internal_account].each do |account|
      body = visit_as(account, "/templates/#{template_for(account).id}/submissions/new")

      expect(body).to include(I18n.t('via_email')), account.account_kind
      expect(body).not_to include(I18n.t('via_phone')), account.account_kind
      expect(body).not_to include('id="phone"'), account.account_kind
    end
  end

  describe 'webhook event resend' do
    def webhook_event_for(account)
      webhook_url = create(:webhook_url, account:, events: ['form.completed'])
      submission = create(:submission, :with_submitters, template: template_for(account),
                                                         created_by_user: admin_for(account))

      event = WebhookEvent.create!(webhook_url:, account:, record: submission.submitters.first,
                                   event_type: 'form.completed', status: 'error')
      event.webhook_attempts.create!(attempt: 1, response_status_code: 500, response_body: 'boom')

      event
    end

    it 'offers the Resend button on the event list and the event drawer only while the account is entitled ' \
       '(the history itself stays visible after a downgrade)' do
      event = webhook_event_for(paid_account)
      resend_path = "/settings/webhooks/#{event.webhook_url_id}/events/#{event.uuid}/resend"
      event_path = "/settings/webhooks/#{event.webhook_url_id}/events/#{event.uuid}"

      expect(visit_as(paid_account, '/settings/webhooks')).to include(resend_path)
      expect(visit_as(paid_account, event_path)).to include(resend_path)
      expect(refreshed_rows_for(paid_account, event)).to include(resend_path)

      downgrade_to_free!(paid_account)

      expect(visit_as(paid_account, '/settings/webhooks')).not_to include(resend_path)

      drawer_body = visit_as(paid_account, event_path)

      expect(drawer_body).to include(event.event_type)
      expect(drawer_body).not_to include(resend_path)

      # The 3-second poll a still-open page keeps sending re-renders both
      # partials; a downgraded account must not get the button back that way.
      refreshed = refreshed_rows_for(paid_account, event)

      expect(refreshed).to include(event.event_type)
      expect(refreshed).not_to include(resend_path)
    end

    def refreshed_rows_for(account, event)
      sign_out(:user)
      reset!
      sign_in(admin_for(account))
      post "/settings/webhooks/#{event.webhook_url_id}/events/#{event.uuid}/refresh", params: { last_attempt_id: 0 }

      expect(response).to have_http_status(:ok)

      response.body
    end
  end

  it 'shows the API tab in template preferences to a free account (discoverable, with the CTA)' do
    body = visit_as(free_account, "/templates/#{template_for(free_account).id}/preferences")

    expect(body).to include('id="api"')
    expect(body).to include(I18n.t('api_and_embedding'))
  end

  it 'lists the paid rows in the settings navigation for a free account' do
    body = visit_as(free_account, '/settings/notifications')

    %w[/settings/api /settings/webhooks /settings/mcp /settings/email].each { |path| expect(body).to include(path) }
    expect(body).not_to include('/settings/sms')
    expect(body).not_to include('/settings/sso')
  end

  it 'has no SMS or SSO settings routes for anyone' do
    sign_in(admin_for(internal_account))

    expect { get '/settings/sms' }.to raise_error(ActionController::RoutingError)
    expect { get '/settings/sso' }.to raise_error(ActionController::RoutingError)
  end

  describe 'SMTP settings saved on a paid plan' do
    let(:smtp_value) do
      { 'host' => 'smtp.example.com', 'port' => '587', 'username' => 'mailer',
        'password' => 'p4ssw0rd-never-shown', 'from_email' => 'docs@example.com' }
    end

    # The pin is inert after a downgrade (MailConfigs.resolve skips it) but the
    # owner must still be able to see and remove it — never the password.
    it 'shows a downgraded account a read-only summary with a remove button, removes on request, and shows an ' \
       'entitled account the real form' do
      config = create(:encrypted_config, account: paid_account, key: EncryptedConfig::EMAIL_SMTP_KEY, value: smtp_value)

      body = visit_as(paid_account, '/settings/email')

      expect(body).to include('name="encrypted_config[value][host]"')
      expect(body).not_to include(I18n.t('remove_smtp_settings'))

      downgrade_to_free!(paid_account)

      body = visit_as(paid_account, '/settings/email')

      expect_cta(body)
      expect(body).not_to include('name="encrypted_config[value][host]"')
      %w[smtp.example.com 587 mailer docs@example.com].each { |value| expect(body).to include(value) }
      expect(body).not_to include('p4ssw0rd-never-shown')
      expect(body).to include(I18n.t('remove_smtp_settings'))
      expect(body).to include("/settings/email/#{config.id}")

      expect { delete "/settings/email/#{config.id}" }.to change(EncryptedConfig, :count).by(-1)
      expect(response).to redirect_to('/settings/email')

      body = visit_as(paid_account, '/settings/email')

      expect_cta(body)
      expect(body).not_to include(I18n.t('remove_smtp_settings'))
    end
  end

  describe 'attribution points' do
    # DOM lookups, never substring checks: an anchor parked inside an HTML
    # comment is still a substring of the body but is not attribution.
    def docuseal_attribution_links(body)
      Nokogiri::HTML(body).css("a[href^='#{Docuseal::DOCUSEAL_URL}']").select { |a| a.text.strip == 'DocuSeal' }
    end

    def product_attribution_links(body)
      Nokogiri::HTML(body).css("a[href='#{Docuseal::PRODUCT_URL}']").select { |a| a.text.strip == Docuseal.product_name }
    end

    def signing_page_for(account)
      submission = create(:submission, :with_submitters, template: template_for(account),
                                                         created_by_user: admin_for(account))
      get "/s/#{submission.submitters.first.slug}"

      expect(response).to have_http_status(:ok)

      response.body
    end

    def qr_page_for(account)
      template = template_for(account)
      template.update!(shared_link: true)

      visit_as(account, "/templates/#{template.id}/share_link_qr")
    end

    it 'renders the DocuSeal attribution on the signing page for free and paid-without-branding accounts; ' \
       'only the "Powered by" wording follows the flag' do
      create(:account_config, account: paid_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)
      create(:account_config, account: free_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      free_body = signing_page_for(free_account)

      expect(free_body).to include(I18n.t('powered_by'))
      expect(docuseal_attribution_links(free_body)).not_to be_empty

      paid_body = signing_page_for(paid_account)

      expect(paid_body).not_to include(I18n.t('powered_by'))
      expect(docuseal_attribution_links(paid_body)).not_to be_empty
    end

    # The shared-link verification-code page (/d/:slug?email_verification=1).
    def shared_link_verification_page_for(account)
      template = template_for(account)
      template.update!(shared_link: true)

      get "/d/#{template.slug}", params: { email_verification: true }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="one_time_code"')

      response.body
    end

    # The signer's email-2FA page (/s/:slug on a template that requires it).
    def email_2fa_page_for(account)
      template = template_for(account)
      template.update!(preferences: template.preferences.merge('require_email_2fa' => true))
      submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))

      get "/s/#{submission.submitters.first.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('send_verification_code'))

      response.body
    end

    def document_not_ready_page_for(account)
      template = template_for(account)
      template.update!(shared_link: true)
      document = template.documents.sole
      document.metadata['converting'] = true
      document.save!

      get "/d/#{template.slug}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('document_not_ready'))

      response.body
    end

    it 'renders the DocuSeal attribution on both signer-facing 2FA pages for free and paid-without-branding accounts' do
      create(:account_config, account: paid_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      bodies = [free_account, paid_account].flat_map do |account|
        [shared_link_verification_page_for(account), email_2fa_page_for(account)]
      end

      bodies.each { |body| expect(docuseal_attribution_links(body)).not_to be_empty }
    end

    it 'renders the DocuSeal attribution on the document-not-ready page for free and paid-without-branding accounts' do
      create(:account_config, account: paid_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      [free_account, paid_account].each do |account|
        body = document_not_ready_page_for(account)

        expect(docuseal_attribution_links(body)).not_to be_empty
      end
    end

    it 'renders the DocuSeal attribution on the public /verify page for an anonymous visitor' do
      sign_out(:user)
      reset!

      get '/verify'

      expect(response).to have_http_status(:ok)
      link = docuseal_attribution_links(response.body).sole
      expect(link['href']).to eq("#{Docuseal::DOCUSEAL_URL}/start")
    end

    it 'renders the share-link QR attribution for free and paid-without-branding accounts alike' do
      create(:account_config, account: paid_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      [free_account, paid_account].each do |account|
        body = qr_page_for(account)

        expect(body).to include(I18n.t('powered_by'))
        expect(product_attribution_links(body)).not_to be_empty
      end
    end
  end
end
