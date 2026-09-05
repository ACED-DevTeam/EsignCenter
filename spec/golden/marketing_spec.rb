# frozen_string_literal: true

# The public face (Session 9 Phase B): the landing page replaces upstream's
# self-host copy, the pricing page is generated from the entitlement matrix
# and the quota constants, the trust page names its sub-processors and backs
# every claim, and none of the three ever links to a sign-up page that does
# not exist.
RSpec.describe 'Marketing pages', type: :request do
  stash_env 'REGISTRATION_ENABLED', clear: true

  # The instance is set up (the operator exists), so the signed-out root
  # renders the landing page instead of the first-run setup redirect.
  before { create(:user, account: create(:account, :operator)) }

  let(:upstream_phrases) { ['self-hosted', 'Docker', 'VPN', 'accesses', 'Open Source Document Signing'] }
  let(:forbidden_trust_phrases) do
    ['ESIGN compliant', 'ESIGN-compliant', 'court-admissible', 'bank-grade', 'SOC 2', 'HIPAA', 'GDPR']
  end
  let(:sub_processors) do
    ['Render', 'Amazon Web Services', 'Postmark', 'Stripe', 'Sentry', 'Cloudflare Turnstile', 'Google', 'DigiCert']
  end
  let(:claims) { %w[consent sealed verify audit us export delete open-source support pricing] }

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
    doc.css("a[href^='#{Docuseal::DOCUSEAL_URL}']").select do |a|
      a.text.strip == 'DocuSeal' && a.ancestors.none? { |node| hidden_node?(node) }
    end
  end

  # The forbidden phrases are checked against the WHOLE page; only the
  # "what we do not claim" paragraph on /trust may name a certification, and
  # only to disclaim it.
  def body_text_outside_disclaimer
    page = doc.dup
    page.css('#not-claimed').remove
    page.at_css('body').text
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
        expect(cell.call(row[:key])).to eq(['Not included', 'Included']), "#{feature} row is not dash / check"
      end
      expect(cell.call('completions')).to eq([Quotas::Limits::FREE_COMPLETIONS_PER_MONTH.to_s, 'Unlimited*'])
      expect(cell.call('sends')).to eq([Quotas::Limits::FREE_SENDS_PER_MONTH.to_s, 'Unlimited*'])
      expect(cell.call('in_flight')).to eq([Quotas::Limits::FREE_IN_FLIGHT.to_s, 'Unlimited*'])
      expect(cell.call('storage')).to eq(['1 GB', '10 GB per seat'])
      expect(cell.call('seats').first).to eq(Quotas::Limits::FREE_SEATS.to_s)
      expect(cell.call('api')).to eq(['Not included', 'Included'])
      expect(cell.call('send_and_sign')).to eq(%w[Included Included])

      forbidden_trust_phrases.each { |phrase| expect(body_text_outside_disclaimer).not_to include(phrase) }
      expect(response.body).to include("$#{StripeBilling::PRICE_PER_SEAT_USD}")
      expect(response.body).to include("#{StripeBilling::TRIAL_PERIOD_DAYS}-day")
      expect(response.body).to include(Quotas::Limits::PAID_COMPLETIONS_REVIEW_PER_SEAT.to_s)
      expect(BillingSettingsController::PRICE_PER_SEAT_USD).to eq(StripeBilling::PRICE_PER_SEAT_USD)

      Entitlements::HIDDEN.each { |feature| expect(rows.map { |r| r['data-pricing-row'] }).not_to include(feature.to_s) }
      %w[SMS bulk SAML SSO formula].each { |word| expect(doc.at_css('table').text).not_to include(word) }
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
    it 'names every sub-processor, backs every claim and makes none of the forbidden ones' do
      get '/trust'

      expect(response).to have_http_status(:ok)
      expect(doc.css('meta[name="robots"]')).to be_empty
      sub_processors.each { |name| expect(response.body).to include(name) }
      claims.each { |claim| expect(doc.css("tr[data-claim='#{claim}']")).not_to be_empty, "missing claim #{claim}" }
      expect(doc.css('#not-claimed')).not_to be_empty
      forbidden_trust_phrases.each { |phrase| expect(body_text_outside_disclaimer).not_to include(phrase) }
      expect(response.body).to include('(an ActiveCampaign company)')
      expect(response.body).to include(Docuseal::SUPPORT_EMAIL)
      expect(doc.css("a[href='#{verify_path}']")).not_to be_empty
      expect(visible_attribution_links).not_to be_empty
    end
  end

  describe 'robots.txt' do
    it 'allows the public pages and disallows the app' do
      robots = Rails.public_path.join('robots.txt').read

      %w[/pricing /trust /terms /privacy /verify].each { |path| expect(robots).to include("Allow: #{path}") }
      %w[/api/ /settings/ /s/ /d/ /operator/].each { |path| expect(robots).to include("Disallow: #{path}") }
    end
  end
end
