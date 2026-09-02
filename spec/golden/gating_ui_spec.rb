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
    'Template preferences API tab (embed)' => [->(t) { "/templates/#{t.id}/preferences" }, ['id="embedding_url"']]
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
      expect(free_body).to include("href=\"#{Docuseal::DOCUSEAL_URL}")
      expect(free_body).to include('>DocuSeal</a>')

      paid_body = signing_page_for(paid_account)

      expect(paid_body).not_to include(I18n.t('powered_by'))
      expect(paid_body).to include("href=\"#{Docuseal::DOCUSEAL_URL}")
      expect(paid_body).to include('>DocuSeal</a>')
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

    it 'renders the DocuSeal attribution on both signer-facing 2FA pages for free and paid-without-branding accounts' do
      create(:account_config, account: paid_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      bodies = [free_account, paid_account].flat_map do |account|
        [shared_link_verification_page_for(account), email_2fa_page_for(account)]
      end

      expect(bodies).to all(include("href=\"#{Docuseal::DOCUSEAL_URL}"))
      expect(bodies).to all(include('>DocuSeal</a>'))
    end

    it 'renders the share-link QR attribution for free and paid-without-branding accounts alike' do
      create(:account_config, account: paid_account, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      [free_account, paid_account].each do |account|
        body = qr_page_for(account)

        expect(body).to include(I18n.t('powered_by'))
        expect(body).to include("href=\"#{Docuseal::PRODUCT_URL}\"")
        expect(body).to include(Docuseal.product_name)
      end
    end
  end
end
