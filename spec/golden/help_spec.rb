# frozen_string_literal: true

# The public help centre (Session 10 Phase B): ten articles anybody can read,
# an index that lists every one of them, and — the point of the file — the
# guarantee that no NUMBER in the prose was typed by hand.
#
# A help page that says "5 documents a month" as a literal is a promise the
# product can silently stop keeping. Every cap, price and window in an article
# body is rendered from the constant that enforces it, and the scan at the
# bottom of this file fails if a digit appears in the prose that is not one of
# the handful of non-product numbers a writer legitimately needs (a hash size,
# an HTTP status class).
RSpec.describe 'Help centre', type: :request do
  # The instance is set up, so a public page is never the first-run redirect.
  before { create(:user, account: create(:account, :operator)) }

  let(:limits) { Quotas::Limits }
  # The same list spec/golden/marketing_spec.rb holds the public pages to.
  let(:forbidden_trust_phrases) do
    ['ESIGN compliant', 'ESIGN-compliant', 'court-admissible', 'bank-grade', 'SOC 2', 'HIPAA', 'GDPR']
  end
  let(:upstream_phrases) { ['self-hosted', 'Docker', 'VPN', 'Open Source Document Signing'] }

  def doc
    Nokogiri::HTML(response.body)
  end

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

  describe 'the registry' do
    it 'holds exactly the ten articles of the brief, each with a partial beside it' do
      expect(HelpCenter.slugs).to eq(%w[getting-started sending-a-document signing-a-document templates-and-fields
                                        free-plan-limits teams-and-seats billing-and-trial verify-a-signed-document
                                        api-and-webhooks your-data-and-deletion])
      HelpCenter.articles.each do |article|
        expect(HelpCenter::ARTICLES_DIR.join("#{article.slug}.html.erb")).to exist
        expect(article.title).to be_present
        expect(article.summary).to be_present
        expect(article.section).to be_present
        expect(article.updated_on).to be_a(Date)
        expect(article.reading_minutes).to be_positive
      end
    end

    it 'has no prose file that the registry does not list, so nothing is written and then lost' do
      written = Dir.children(HelpCenter::ARTICLES_DIR).grep(/\.html\.erb\z/).map { |name| name.delete_suffix('.html.erb') }

      expect(written.sort).to eq(HelpCenter.slugs.sort)
    end

    it 'is the ONE source of truth: the module reads the YAML the writer edits' do
      expect(HelpCenter::REGISTRY_PATH.to_s).to end_with('app/views/help/articles/REGISTRY.yml')
      registry = YAML.safe_load_file(HelpCenter::REGISTRY_PATH, permitted_classes: [Date])
      expect(HelpCenter.articles.map(&:title)).to eq(registry.pluck('title'))
    end
  end

  describe 'GET /help' do
    it 'lists every article, grouped by section, to an anonymous visitor' do
      get '/help'

      expect(response).to have_http_status(:ok)
      HelpCenter.articles.each do |article|
        link = doc.at_css("a[href='#{help_article_path(article.slug)}']")
        expect(link).to be_present, "no card for #{article.slug}"
        expect(link.text).to include(article.title, article.summary)
      end
      expect(doc.css('h2').map { |h| h.text.squish }).to include(*HelpCenter.sections.keys)
    end

    it 'is indexable, canonical and titled, and carries the visible DocuSeal attribution' do
      get '/help'

      expect(doc.css('meta[name="robots"]')).to be_empty
      expect(doc.at_css('link[rel="canonical"]')['href']).to eq(help_url)
      expect(doc.at_css('title').text.squish).to include('Help centre')
      expect(visible_attribution_links).not_to be_empty
    end

    it 'points at the support form and the API reference' do
      get '/help'

      expect(doc.css("a[href='#{support_path}']")).not_to be_empty
      expect(doc.css("a[href='#{api_reference_path}']")).not_to be_empty
    end
  end

  describe 'GET /help/:slug' do
    it 'renders every article to an anonymous visitor, with its title, updated date and reading time' do
      HelpCenter.articles.each do |article|
        get help_article_path(article.slug)

        expect(response).to have_http_status(:ok), "#{article.slug} did not render"
        expect(doc.at_css('h1').text.squish).to eq(article.title)
        expect(doc.at_css('time')['datetime']).to eq(article.updated_on.iso8601)
        expect(doc.at_css('main').text).to include(article.updated_on.strftime('%-d %B %Y'))
        expect(doc.at_css('main').text).to include("#{article.reading_minutes} minute")
        expect(doc.at_css('article.help-article')).to be_present
      end
    end

    it 'offers "was this helpful" to /support and chains prev/next without wrapping' do
      HelpCenter.articles.each_with_index do |article, index|
        get help_article_path(article.slug)

        expect(doc.css("a[href='#{support_path}']")).not_to be_empty, "#{article.slug} has no support link"
        previous_link = doc.at_css("a[rel='prev']")
        next_link = doc.at_css("a[rel='next']")

        if index.zero?
          expect(previous_link).to be_nil
        else
          expect(previous_link['href']).to eq(help_article_path(HelpCenter.articles[index - 1].slug))
        end

        if index == HelpCenter.articles.size - 1
          expect(next_link).to be_nil
        else
          expect(next_link['href']).to eq(help_article_path(HelpCenter.articles[index + 1].slug))
        end
      end
    end

    it 'answers an unknown slug with a 404, not a 500' do
      expect { get '/help/no-such-article' }.to raise_error(ActionController::RoutingError)
      expect { HelpCenter.article!('no-such-article') }.to raise_error(HelpCenter::UnknownArticle)
    end

    it 'says nothing this product has decided never to claim, and none of the upstream self-host copy' do
      HelpCenter.slugs.each do |slug|
        get help_article_path(slug)

        forbidden_trust_phrases.each do |phrase|
          expect(response.body).not_to include(phrase), "#{slug} says #{phrase}"
        end
        upstream_phrases.each do |phrase|
          expect(response.body).not_to include(phrase), "#{slug} says #{phrase}"
        end
      end
    end

    it 'cross-links only to articles that exist' do
      HelpCenter.slugs.each do |slug|
        get help_article_path(slug)

        doc.css("a[href^='/help/']").each do |link|
          target = link['href'].delete_prefix('/help/')

          expect(HelpCenter.slugs).to include(target), "#{slug} links to a missing article #{target}"
        end
      end
    end
  end

  # --- the numbers -----------------------------------------------------------

  describe 'every product number comes from its constant' do
    # The only digits a writer may type into an article: a starting count, a
    # hash size and the two HTTP status classes. Deliberately tiny, and with
    # nothing about the product in it — every cap, price and window is
    # rendered from its constant, and the scan at the foot of this group is
    # what makes that true rather than merely intended.
    let(:non_product_numbers) { %w[0 256 4xx 5xx] }

    it 'renders the free-plan caps from Quotas::Limits' do
      get help_article_path('free-plan-limits')

      body = doc.at_css('article.help-article').text
      expect(body).to include("#{limits::FREE_COMPLETIONS_PER_MONTH} completed documents a month")
      expect(body).to include("#{limits::FREE_SENDS_PER_MONTH} documents sent a month")
      expect(body).to include("#{limits::FREE_IN_FLIGHT} documents out for signature at once")
      expect(body).to include("#{limits::FREE_SEATS} user")
      expect(body).to include(ActiveSupport::NumberHelper.number_to_human_size(limits::FREE_STORAGE_BYTES))
      expect(body).to include(ActiveSupport::NumberHelper.number_to_human_size(limits::PAID_STORAGE_BYTES_PER_SEAT))
      expect(body).to include(limits::FREE_COMPLETIONS_WARNING_AT.to_s)
    end

    it 'renders the trial length and the seat price from StripeBilling' do
      get help_article_path('billing-and-trial')

      body = doc.at_css('article.help-article').text
      expect(body).to include(StripeBilling::TRIAL_PERIOD_DAYS.to_s)
      expect(body).to include(StripeBilling::PRICE_PER_SEAT_USD.to_s)
    end

    it 'renders the retention and recovery windows from the constants that enforce them' do
      get help_article_path('your-data-and-deletion')

      body = doc.at_css('article.help-article').text
      expect(body).to include(Accounts::Deletion::WINDOW_DAYS.to_s)
      expect(body).to include(Accounts::Retention::PAID_RETENTION.inspect)
      expect(body).to include(Accounts::Exports::MAX_PER_DAY.to_s)
    end

    # The scan itself.
    it 'has no product number typed into any article body' do
      HelpCenter.articles.each do |article|
        source = HelpCenter::ARTICLES_DIR.join("#{article.slug}.html.erb").read
        prose = source.gsub(/<%.*?%>/m, ' ').gsub(/<[^>]+>/m, ' ')
        numbers = prose.scan(/\d[\dx,.]*/).map { |token| token.sub(/[.,]\z/, '') }.uniq

        typed = numbers - non_product_numbers

        expect(typed).to be_empty,
                         "#{article.slug} types the number(s) #{typed.inspect} into its prose; render it from " \
                         'the constant that enforces it instead'
      end
    end
  end
end
