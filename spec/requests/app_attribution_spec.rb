# frozen_string_literal: true

# AGPL LICENSE_ADDITIONAL_TERMS and section 13 reach the people who run an
# account too, not only their signers: every layout of the signed-in app, the
# form-layout pages without a footer of their own and the signed-out sign-in
# page each carry the DocuSeal credit (pointing at its source repository) and
# the link to this fork's own source, exactly once. The credit stays even for
# a paid account that switched its branding off; only the "Powered by" wording
# follows that flag, as on the signing pages.
describe 'Attribution in the app' do
  let(:account) { create(:account, :paid) }
  let(:admin) { create(:user, :admin, account:) }

  def attribution_links(body)
    page = Nokogiri::HTML(body)

    {
      docuseal: page.css("a[href='#{Docuseal::DOCUSEAL_SOURCE_URL}']").select { |a| a.text.strip == 'DocuSeal' },
      source: page.css("a[href='#{Docuseal::GITHUB_URL}']").select { |a| a.text.strip == 'Source' }
    }
  end

  def expect_attribution(body, powered_by: true)
    links = attribution_links(body)

    expect(links[:docuseal]).not_to be_empty
    expect(links[:source]).not_to be_empty

    if powered_by
      expect(body).to include(I18n.t('powered_by'))
    else
      expect(body).not_to include(I18n.t('powered_by'))
    end
  end

  it 'shows the attribution on signed-in pages' do
    sign_in(admin)

    ['/', '/submissions', '/settings/profile'].each do |path|
      get path

      expect(response).to have_http_status(:ok), "#{path} answered #{response.status}"
      expect_attribution(response.body)
    end
  end

  # These screens render with the plain layout rather than the main one.
  it 'shows the attribution once on the signed-in plain-layout screens' do
    template = create(:template, account:, author: admin)
    submission = create(:submission, :with_submitters, template:, created_by_user: admin)
    sign_in(admin)

    paths = ["/templates/#{template.id}/edit", "/templates/#{template.id}/preview", "/submissions/#{submission.id}"]

    paths.each do |path|
      get path

      expect(response).to have_http_status(:ok), "#{path} answered #{response.status}"
      expect_attribution(response.body)
      expect(attribution_links(response.body)[:docuseal].size).to eq(1), "#{path} drew the attribution more than once"
    end
  end

  # The form layout carries the signing pages, which draw their own footer, and
  # a few pages that do not: an invitation and a signer's document report.
  it 'shows the attribution once on form-layout pages that have no footer of their own' do
    template = create(:template, account:, author: admin)
    submission = create(:submission, :with_submitters, template:, created_by_user: admin)

    { '/invites/not-a-real-token' => :gone,
      "/report/#{submission.submitters.first.slug}" => :ok,
      "/s/#{submission.submitters.first.slug}" => :ok }.each do |path, status|
      get path

      expect(response).to have_http_status(status), "#{path} answered #{response.status}"
      expect_attribution(response.body)
      expect(attribution_links(response.body)[:docuseal].size).to eq(1), "#{path} drew the attribution more than once"
    end
  end

  # The phone signature pad (the "sign on your phone" QR code) has no layout.
  it 'shows the attribution once on the phone signature pad' do
    template = create(:template, account:, author: admin)
    submission = create(:submission, :with_submitters, template:, created_by_user: admin)
    submitter = submission.submitters.first
    signature = template.fields.find { |f| f['type'] == 'signature' && f['submitter_uuid'] == submitter.uuid }

    get "/p/#{submitter.slug}", params: { f: signature['uuid'].first(8) }

    expect(response).to have_http_status(:ok)
    expect_attribution(response.body)
    expect(attribution_links(response.body)[:docuseal].size).to eq(1)
  end

  # A public page follows the branding of the account it belongs to, not of
  # whoever happens to be signed in (or nobody) while reading it.
  it "follows the page-owning account's branding on an invitation and a document report" do
    create(:account_config, account:, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)
    invite = create(:account_invite, account:)
    template = create(:template, account:, author: admin)
    submission = create(:submission, :with_submitters, template:, created_by_user: admin)

    get "/invites/#{invite.raw_token}"

    expect(response).to have_http_status(:ok)
    expect_attribution(response.body, powered_by: false)

    reader_account = create(:account)
    sign_in(create(:user, :admin, account: reader_account))

    get "/report/#{submission.submitters.first.slug}"

    expect(response).to have_http_status(:ok)
    expect_attribution(response.body, powered_by: false)
  end

  it 'shows the attribution on the signed-out sign-in page' do
    create(:user)

    get '/sign_in'

    expect(response).to have_http_status(:ok)
    expect_attribution(response.body)
  end

  it 'keeps the DocuSeal credit and source link when a paid account removes its branding' do
    create(:account_config, account:, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)
    sign_in(admin)

    get '/'

    expect(response).to have_http_status(:ok)
    expect_attribution(response.body, powered_by: false)
  end
end
