# frozen_string_literal: true

# AGPL LICENSE_ADDITIONAL_TERMS and section 13 reach the people who run an
# account too, not only their signers: the signed-in app, the template builder
# and the signed-out sign-in page each carry the DocuSeal credit (pointing at
# its source repository) and the link to this fork's own source. The credit
# stays even for a paid account that switched its branding off; only the
# "Powered by" wording follows that flag, as it does on the signing pages.
describe 'Attribution in the app' do
  let(:account) { create(:account, :paid) }
  let(:admin) { create(:user, :admin, account:) }

  def attribution_links(body)
    footer = Nokogiri::HTML(body).css('footer, .text-center').to_a

    {
      docuseal: footer.flat_map { |node| node.css("a[href='#{Docuseal::DOCUSEAL_SOURCE_URL}']") }
                      .select { |a| a.text.strip == 'DocuSeal' },
      source: footer.flat_map { |node| node.css("a[href='#{Docuseal::GITHUB_URL}']") }
                    .select { |a| a.text.strip == 'Source' }
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

  it 'shows the attribution in the template builder' do
    template = create(:template, account:, author: admin)
    sign_in(admin)

    get "/templates/#{template.id}/edit"

    expect(response).to have_http_status(:ok)
    expect_attribution(response.body)
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
