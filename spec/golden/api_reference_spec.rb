# frozen_string_literal: true

# The public API reference (Session 10 Phase B): the page at /docs/api and the
# machine-readable description at /docs/openapi.json it reads.
#
# What this file protects:
#
#   * the served description is THIS instance's — no reader is ever told to
#     curl `your-instance.example.com`;
#   * rewriting it never drops an operation: every path in the authored
#     docs/openapi.json is still there;
#   * the reference is bundled from this origin, so it runs under the
#     application's own `script_src 'self'` policy with no CDN and no widening;
#   * the in-app "open the full API reference" button goes to this page.
RSpec.describe 'API reference', type: :request do
  before { create(:user, account: create(:account, :operator)) }

  def doc
    Nokogiri::HTML(response.body)
  end

  describe 'GET /docs/openapi.json' do
    it 'parses, points servers[0] at this instance and mentions no placeholder host' do
      get '/docs/openapi.json'

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/json')
      expect(response.body).not_to include('your-instance')

      document = JSON.parse(response.body)
      expect(document['servers'].first['url']).to eq("#{Docuseal::DEFAULT_APP_URL}/api")
      expect(document['info']['contact']['url']).to eq(OpenapiDocument::CONTACT_URL)
      expect(document['openapi']).to be_present
    end

    it 'still describes every path the authored document does' do
      get '/docs/openapi.json'

      expect(JSON.parse(response.body)['paths'].keys).to match_array(OpenapiDocument.authored_paths)
      expect(OpenapiDocument.authored_paths).not_to be_empty
    end

    it 'rewrites the placeholder origin everywhere it appears, not only in servers' do
      authored = OpenapiDocument::PATH.read

      expect(authored.scan(OpenapiDocument::PLACEHOLDER_ORIGIN).size).to be > 1
      expect(OpenapiDocument.json).not_to include('your-instance.example.com')
      expect(OpenapiDocument.json).to include("#{OpenapiDocument.app_url}/file/hash/example.pdf")
    end

    it 'is cacheable for an hour and built once per process until the file changes' do
      get '/docs/openapi.json'

      expect(response.headers['Cache-Control']).to include('public', 'max-age=3600')
      # The same String object comes back while the file on disk is unchanged.
      expect(OpenapiDocument.json).to equal(OpenapiDocument.json)
    end
  end

  describe 'GET /docs/api' do
    it 'renders to an anonymous visitor with the base URL, the auth header and the plan note' do
      get '/docs/api'

      expect(response).to have_http_status(:ok)
      main = doc.at_css('main')
      expect(main.at_css('h1').text.squish).to eq('API reference')
      expect(main.text).to include("#{Docuseal::DEFAULT_APP_URL}/api")
      expect(main.text).to include('X-Auth-Token')
      expect(main.text).to include('API tokens are on the paid plan')
      expect(main.css("a[href='#{pricing_path}']")).not_to be_empty
    end

    it 'mounts the reference on a div pointed at the description on this origin' do
      get '/docs/api'

      mount = doc.at_css('#api-reference')
      expect(mount).to be_present
      expect(mount['data-spec-url']).to eq('/docs/openapi.json')
    end

    it 'loads its own pack and no third-party script, under the application policy unwidened' do
      get '/docs/api'

      sources = doc.css('script[src]').pluck('src')
      expect(sources).to include(a_string_matching(%r{/packs.*/api_reference}))
      expect(sources).to all(start_with('/'))
      expect(doc.css('link[rel="stylesheet"]').pluck('href')).to all(start_with('/'))

      policy = response.headers['Content-Security-Policy']
      expect(policy).to match(/script-src 'self'[;\s]/)
      expect(policy).to match(/connect-src 'self'(;|\z)/)
      expect(policy).not_to include('cdn.')
      expect(policy).not_to include('challenges.cloudflare.com')
    end

    it 'is indexable, canonical and linked from the help centre and the marketing footer' do
      get '/docs/api'

      expect(doc.css('meta[name="robots"]')).to be_empty
      expect(doc.at_css('link[rel="canonical"]')['href']).to eq(api_reference_url)
      expect(doc.css("a[href='#{help_article_path('api-and-webhooks')}']")).not_to be_empty
      expect(doc.css("a[href='#{support_path}']")).not_to be_empty

      get '/pricing'
      expect(doc.css("a[href='#{api_reference_path}']")).not_to be_empty
    end
  end

  describe 'the in-app button' do
    it 'sends a paid account from API settings to this page rather than to a source tree' do
      user = create(:user, account: create(:account, :paid))
      sign_in user

      get settings_api_index_path

      # Scoped past the navbar dropdown, which now links here too: this is the
      # button at the foot of the API settings page.
      link = doc.css("a[href='#{api_reference_path}']").find { |a| a['class'].to_s.include?('btn') }
      expect(link).to be_present
      expect(link.text.squish).to eq(I18n.t('open_full_api_reference'))
      expect(link['target']).to be_nil
    end
  end
end
