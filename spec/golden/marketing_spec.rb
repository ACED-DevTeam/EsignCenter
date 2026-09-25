# frozen_string_literal: true

# The public face (Session 9 Phase B): the landing page replaces upstream's
# self-host copy, the pricing page is generated from the entitlement matrix
# and the quota constants, the trust page names its sub-processors and backs
# every claim, and none of the three ever links to a sign-up page that does
# not exist.
RSpec.describe 'Marketing pages', type: :request do
  stash_env 'REGISTRATION_ENABLED', 'STRIPE_BUSINESS_PRICE_ID', clear: true

  # The instance is set up (the operator exists), so the signed-out root
  # renders the landing page instead of the first-run setup redirect.
  before { create(:user, account: create(:account, :operator)) }

  let(:upstream_phrases) { ['self-hosted', 'Docker', 'VPN', 'accesses', 'Open Source Document Signing'] }
  let(:forbidden_trust_phrases) do
    ['ESIGN compliant', 'ESIGN-compliant', 'court-admissible', 'bank-grade', 'SOC 2', 'HIPAA', 'GDPR']
  end
  let(:sub_processors) do
    ['Render', 'Amazon Web Services', 'Postmark', 'Stripe', 'Sentry', 'Cloudflare Turnstile', 'Google', 'Apple',
     'DigiCert']
  end
  let(:claims) { %w[consent sealed verify audit us export delete open-source support pricing] }

  # The one certification line the site may carry. The reports are the hosting
  # and storage providers', never EsignCenter's own, and the #not-claimed
  # paragraph on /trust says so. Any other wording ("SOC 2 compliant", "SOC 2
  # servers") still fails.
  let(:infrastructure_claim) { 'Built on SOC 2 Type II audited infrastructure.' }

  def doc
    Nokogiri::HTML(response.body)
  end

  # The AGPL attribution must be rendered AND visible: an anchor inside an
  # element carrying the `hidden` attribute, an inline display:none, or
  # Tailwind's `hidden` / `invisible` classes is not attribution.
  def hidden_node?(node)
    return false unless node.element?

    classes = node['class'].to_s.split
    node.has_attribute?('hidden') || node['style'].to_s.match?(/display\s*:\s*none|visibility\s*:\s*hidden/) ||
      classes.include?('hidden') || classes.include?('invisible')
  end

  def visible_attribution_links
    doc.css("a[href^='#{Docuseal::DOCUSEAL_SOURCE_URL}']").select do |a|
      a.text.strip == 'DocuSeal' && a.ancestors.none? { |node| hidden_node?(node) }
    end
  end

  # The forbidden phrases are checked against the WHOLE page; only the
  # "what we do not claim" paragraph on /trust may name a certification, and
  # only to disclaim it. The exact infrastructure line above is the one
  # exception elsewhere.
  def body_text_outside_disclaimer
    page = doc.dup
    page.css('#not-claimed').remove
    page.at_css('body').text.squish.gsub(infrastructure_claim, '')
  end

  # A tick or dash cell reads by its screen-reader text; a value cell by its value.
  def cell
    lambda do |key|
      doc.at_css("tr[data-pricing-row='#{key}']").css('td').map { |td| (td.at_css('.sr-only') || td).text.squish }
    end
  end

  def signup_links
    doc.css("a[href='#{new_registration_path}']")
  end

  describe 'GET /' do
    it 'renders the EsignCenter landing page with none of the upstream self-host copy' do
      get '/'

      expect(response).to have_http_status(:ok)
      main = doc.at_css('main#main')
      headline = main.at_css('h1')
      headline.css('br').each { |br| br.replace(' ') }
      expect(headline.text.squish).to eq('Send it. Get it signed. Prove it.')
      expect(main.text).to include('Upload a PDF or Word file, add who signs, and send.')
      expect(main.css('h3').map { |h| h.text.squish })
        .to include('Upload or pick a template', 'Add who signs', 'Send', 'Signed and sealed')
      expect(main.css('h2').map { |h| h.text.squish }).to include('Proof, built into every document')
      expect(main.text.squish).to include(infrastructure_claim)
      # The reports are the providers', not ours; the line points at the paragraph that says so.
      expect(main.css("a[href='/trust#not-claimed']")).not_to be_empty
      upstream_phrases.each { |phrase| expect(response.body).not_to include(phrase) }
      forbidden_trust_phrases.each { |phrase| expect(body_text_outside_disclaimer).not_to include(phrase) }
      expect(visible_attribution_links).not_to be_empty
      expect(doc.css("a[href='#{Docuseal::GITHUB_URL}']")).not_to be_empty
      %w[/pricing /trust /terms /privacy /verify /sign_in].each do |path|
        expect(doc.css("a[href='#{path}']")).not_to be_empty, "expected a link to #{path}"
      end
    end

    it 'has no noindex and points social previews at the 1200x630 og.png that ships in public/' do
      get '/'

      expect(doc.css('meta[name="robots"]')).to be_empty
      expect(doc.at_css('meta[property="og:image"]')['content']).to end_with('/og.png')
      expect(doc.at_css('meta[name="twitter:card"]')['content']).to eq('summary_large_image')
      expect(doc.at_css('meta[property="og:image:width"]')['content']).to eq('1200')
      expect(Rails.public_path.join('og.png')).to exist
      expect(Rails.public_path.join('preview.png')).not_to exist
      expect(doc.at_css('title').text).to include('Send it. Get it signed. Prove it.')
    end

    it 'offers only Sign in while registration is off, so nothing links to the 404 sign-up page' do
      get '/'

      expect(signup_links).to be_empty
      expect(response.body).not_to include('Start free')
      expect(doc.css("a[href='#{new_user_session_path}']")).not_to be_empty
    end

    it 'points Start free at the registration page while registration is on' do
      ENV['REGISTRATION_ENABLED'] = 'true'

      get '/'

      expect(signup_links.map { |a| a.text.strip }).to include('Start free')
    end
  end

  describe 'GET /pricing' do
    it 'covers every paid-only feature of the entitlement matrix and prints the real constants' do
      get '/pricing'

      expect(response).to have_http_status(:ok)
      expect(doc.css('meta[name="robots"]')).to be_empty

      rows = doc.css('tr[data-pricing-row]')
      expect(rows.size).to eq(PricingMatrix.rows.size)

      # Every row's label is on the page, and every feature the app gates
      # behind the paid plan has a row that reads dash / check.
      PricingMatrix.rows.each do |row|
        expect(doc.at_css("tr[data-pricing-row='#{row[:key]}'] th").text.squish).to eq(I18n.t(row[:label_key]))
      end
      Entitlements::PAID_ONLY.each do |feature|
        row = PricingMatrix.rows.find { |r| r[:features].include?(feature) }
        expect(row).not_to be_nil, "no pricing row covers #{feature}"
        expect(cell.call(row[:key])).to eq(['Not included', 'Included', 'Included', 'Included']),
                                        "#{feature} row is not dash / check"
      end
      expect(cell.call('completions')).to eq([Quotas::Limits::FREE_COMPLETIONS_PER_MONTH.to_s, 'Unlimited*',
                                              'Unlimited*', 'Custom'])
      expect(cell.call('sends')).to eq([Quotas::Limits::FREE_SENDS_PER_MONTH.to_s, 'Unlimited*', 'Unlimited*',
                                        'Custom'])
      expect(cell.call('in_flight')).to eq([Quotas::Limits::FREE_IN_FLIGHT.to_s, 'Unlimited*', 'Unlimited*', 'Custom'])
      expect(cell.call('seats').first).to eq(Quotas::Limits::FREE_SEATS.to_s)
      expect(cell.call('api')).to eq(['Not included', 'Included', 'Included', 'Included'])
      expect(cell.call('send_and_sign')).to eq(%w[Included Included Included Included])

      forbidden_trust_phrases.each { |phrase| expect(body_text_outside_disclaimer).not_to include(phrase) }
      expect(response.body).to include("$#{StripeBilling::PRICE_PER_SEAT_USD}")
      expect(response.body).to include("#{StripeBilling::TRIAL_PERIOD_DAYS}-day")
      expect(response.body).to include(Quotas::Limits::PAID_COMPLETIONS_REVIEW_PER_SEAT.to_s)
      expect(BillingSettingsController::PRICE_PER_SEAT_USD).to eq(StripeBilling::PRICE_PER_SEAT_USD)

      Entitlements::HIDDEN.each { |feature| expect(rows.map { |r| r['data-pricing-row'] }).not_to include(feature.to_s) }
      %w[SMS bulk SAML SSO formula].each { |word| expect(doc.at_css('table').text).not_to include(word) }
    end

    # Storage is included on every plan and never quoted as a size (owner
    # decision); sales tax is not collected at launch (D22), so the page must
    # not say it is added.
    it 'sells storage as included with no size, and says nothing about tax' do
      get '/pricing'

      main = doc.at_css('main').text
      expect(cell.call('storage')).to eq(%w[Included Included Included Included])
      expect(doc.at_css("tr[data-pricing-row='storage'] th").text.squish).to eq('Agreement storage')
      expect(main).not_to match(/\b\d+(\.\d+)?\s*(GB|TB|gigabytes?)\b/i)
      [Quotas::Limits::FREE_STORAGE_BYTES, Quotas::Limits::PAID_STORAGE_BYTES_PER_SEAT].each do |bytes|
        expect(main).not_to include(ActiveSupport::NumberHelper.number_to_human_size(bytes))
      end
      expect(main).not_to include('storage cap')
      expect(doc.at_css('#fair-use').text).to include('Prices in US dollars.')
      expect(main).not_to match(/\btax/i)
    end

    it 'shows API allowances, packs and an Enterprise sales contact' do
      get '/pricing'

      expect(cell.call('api_completions')).to eq(['Not included', '50', '500', 'Custom'])
      expect(cell.call('api_packs')[1..2]).to eq(['+50 for $10/mo'] * 2)
      expect(doc.at_css('[data-enterprise-contact]')['href']).to eq(support_path)
      expect(doc.css('[data-pricing-plan] h2').map(&:text)).to include('Business', 'Enterprise')
    end

    it 'offers an available Business trial and explains the mobile comparison' do
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['STRIPE_BUSINESS_PRICE_ID'] = 'price_business'

      get '/pricing'

      business = doc.at_css('[data-pricing-plan="business"]')
      expect(business.at_css('a.btn').text).to eq('Start free trial')
      expect(business.at_css('a.btn')['href']).to eq(new_registration_path)
      expect(business.text).to include('Choose Business in Billing after signup')
      expect(doc.at_css('#pricing-swipe-hint').text).to eq('Swipe to compare →')
      expect(doc.at_css('[data-pricing-scroll] th[scope="row"]')['class']).to include('sticky left-0')
      %w[business enterprise].each do |plan|
        expect(doc.css("[data-pricing-plan='#{plan}'] li svg").size)
          .to eq(doc.css("[data-pricing-plan='#{plan}'] li").size)
      end
    end

    it 'never links to sign-up while registration is off, and does while it is on' do
      get '/pricing'

      expect(signup_links).to be_empty

      ENV['REGISTRATION_ENABLED'] = 'true'

      get '/pricing'

      expect(signup_links).not_to be_empty
    end

    it 'shows a signed-in user the way back to their dashboard instead of Sign in' do
      sign_in(create(:user))

      get '/pricing'

      expect(response).to have_http_status(:ok)
      nav = doc.at_css('nav[aria-label="Main"]')
      expect(nav.css('a').map { |a| a.text.strip }).to include('Dashboard')
      expect(nav.css("a[href='#{new_user_session_path}']")).to be_empty
    end
  end

  describe 'GET /trust' do
    it 'links to the sub-processors, backs every claim and makes none of the forbidden ones' do
      get '/trust'

      expect(response).to have_http_status(:ok)
      expect(doc.css('meta[name="robots"]')).to be_empty
      expect(doc.css("main a[href='#{subprocessors_path}']")).not_to be_empty
      expect(doc.at_css('[data-soc2]').text.squish).to eq(infrastructure_claim)
      expect(doc.at_css('#not-claimed').text).to include('not to us')
      claims.each { |claim| expect(doc.css("tr[data-claim='#{claim}']")).not_to be_empty, "missing claim #{claim}" }
      expect(doc.css('#not-claimed')).not_to be_empty
      forbidden_trust_phrases.each { |phrase| expect(body_text_outside_disclaimer).not_to include(phrase) }
      expect(response.body).to include(Docuseal::SUPPORT_EMAIL)
      expect(doc.css("a[href='#{verify_path}']")).not_to be_empty
      expect(visible_attribution_links).not_to be_empty
    end

    it 'names the operating company, not only the product, in the footer copyright' do
      get '/trust'

      expect(doc.at_css('footer [data-copyright]').text.squish)
        .to eq("© #{Time.current.year} EsignCenter LLC. Hosted in the United States.")
    end

    it 'keeps Trust out of the main nav and in the footer, beside Sub-processors' do
      get '/trust'

      expect(doc.css("nav[aria-label='Main'] a[href='#{trust_path}']")).to be_empty
      legal = doc.at_css("nav[aria-label='Legal']")
      expect(legal.css("a[href='#{trust_path}']")).not_to be_empty
      expect(legal.css("a[href='#{subprocessors_path}']")).not_to be_empty
    end
  end

  describe 'GET /trust/subprocessors' do
    it 'names every sub-processor and makes none of the forbidden claims' do
      get '/trust/subprocessors'

      expect(response).to have_http_status(:ok)
      expect(doc.css('meta[name="robots"]')).to be_empty
      expect(doc.at_css('h1').text.squish).to eq('Sub-processors')
      sub_processors.each { |name| expect(doc.at_css('table').text).to include(name) }
      expect(response.body).to include('(an ActiveCampaign company)')
      forbidden_trust_phrases.each { |phrase| expect(body_text_outside_disclaimer).not_to include(phrase) }
      expect(doc.css("a[href='#{trust_path}']")).not_to be_empty
      row = ->(name) { doc.css('tbody tr').find { |tr| tr.at_css('th').text.squish == name }.text.squish }
      # Turnstile guards the support form as well as sign-up
      # (SupportRequestsController), and Sentry is described the way the
      # Privacy Policy describes it.
      expect(row.call('Cloudflare Turnstile')).to include('sign-up and support forms')
      expect(row.call('Cloudflare Turnstile')).not_to include('once, at sign-up')
      expect(row.call('Sentry')).to include('can include parts of the request that caused it')
      expect(row.call('Apple')).to include('private relay address')
    end

    it 'names every company the Privacy Policy lists as a sub-processor' do
      get '/trust/subprocessors'

      page_names = doc.at_css('table').text
      privacy = Nokogiri::HTML(LegalDocuments.html(:privacy))
      companies = privacy.css('table').find { |table| table.text.include?('DigiCert') }.css('tbody tr td:first-child')

      expect(companies.size).to eq(doc.css('tbody tr').size)
      companies.each { |company| expect(page_names).to include(company.text.squish) }
      expect(doc.css("a[href='#{privacy_path}']")).not_to be_empty
      expect(visible_attribution_links).not_to be_empty
    end
  end

  # RFC 9116. Served as a static file by ActionDispatch::Static (production
  # enables the public file server), so this walks the real middleware stack.
  # The Expires check is meant to go red: when it does, renew the file for
  # another year (less than a year out, per the RFC) — a stale security.txt
  # tells researchers the contact is not looked after.
  describe 'GET /.well-known/security.txt' do
    it 'publishes the security contact, a future expiry, the language and its canonical address' do
      get '/.well-known/security.txt'

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/plain')

      fields = response.body.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
                       .to_h { |line| line.split(': ', 2) }

      expect(fields['Contact']).to eq("mailto:#{Docuseal::SUPPORT_EMAIL}")
      expect(fields['Preferred-Languages']).to eq('en')
      expect(fields['Canonical']).to eq('https://esigncenter.com/.well-known/security.txt')
      expect(fields['Expires']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z\z/)
      expect(Time.iso8601(fields['Expires'])).to be > Time.current
    end
  end

  describe 'robots.txt' do
    it 'allows the public pages and disallows the app' do
      robots = Rails.public_path.join('robots.txt').read

      %w[/pricing /trust /terms /privacy /verify].each { |path| expect(robots).to include("Allow: #{path}") }
      expect(Rails.public_path.join('sitemap.xml').read).to include('/trust/subprocessors')
      %w[/api/ /settings/ /s/ /d/ /operator/].each { |path| expect(robots).to include("Disallow: #{path}") }
    end
  end
end
