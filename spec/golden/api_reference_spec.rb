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

  # `/api/templates/:id(.:format)` (the router) and `/templates/{id}` (the
  # document) are the same operation written two ways, and a nested route
  # names the same value `:template_id` that the document calls `{id}`. Reduce
  # every parameter on both sides to one placeholder so what is compared is
  # the LITERAL segments — which is exactly what tells `/templates/{id}`, a
  # real door, from `/templates/archived`, an invented one that a wildcard
  # would happily swallow.
  def path_shape(path)
    path.delete_suffix('(.:format)').gsub(/:\w+|\{\w+\}/, '{}')
  end

  # Every verb+path this application really answers under `/api`, in that
  # shape.
  def routed_operations
    Rails.application.routes.routes.filter_map do |route|
      spec = path_shape(route.path.spec.to_s)

      next unless spec.start_with?('/api/')
      next if route.verb.blank?

      "#{route.verb} #{spec}"
    end.uniq
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

    # Review 10, A-F1/N-F1. The example above compares the served document to
    # the file it was built from — it catches a DROPPED operation and nothing
    # else. Eight of the operations this document advertised were upstream-Pro
    # endpoints this fork has never routed (`POST /templates/{pdf,docx,html,
    # merge}`, `POST /submissions/{pdf,docx,html}`, `PUT /templates/{id}/
    # documents`): Scalar drew them as live operations on OUR origin, so a
    # developer following the reference got a routing 404 from us. This is the
    # regression test — every operation the reader is shown has to be one this
    # application actually answers, checked against the router rather than
    # against a hand-kept list.
    #
    # EXACT match, not `recognize_path` (review 10, loop 2). Recognition asks
    # "does some route swallow this URL", and a resource's `:id` wildcard
    # swallows any invented GET sub-path: `GET /templates/archived` recognised
    # as `templates#show id: "archived"` and passed, while the reader who
    # followed it got a 404 from the finder. So each documented verb+path has
    # to EQUAL a route this application declares, segment for segment.
    it 'advertises no operation this application does not route' do
      get '/docs/openapi.json'

      routed = routed_operations

      unroutable =
        JSON.parse(response.body).fetch('paths').flat_map do |path, operations|
          operations.keys.filter_map do |verb|
            next unless verb.in?(%w[get post put patch delete])

            operation = "#{verb.upcase} /api#{path_shape(path)}"

            operation unless routed.include?(operation)
          end
        end

      expect(routed).not_to be_empty
      expect(unroutable).to be_empty,
                            "the published API reference advertises #{unroutable.size} operation(s) this app does " \
                            "not route, so a developer following it gets a 404 from us: #{unroutable.join(', ')}"
    end

    it 'points every operation at a controller action that exists' do
      get '/docs/openapi.json'

      missing =
        JSON.parse(response.body).fetch('paths').flat_map do |path, operations|
          operations.keys.filter_map do |verb|
            next unless verb.in?(%w[get post put patch delete])

            route = Rails.application.routes.recognize_path("/api#{path.gsub(/\{\w+\}/, '1')}", method: verb.to_sym)
            controller = "#{route[:controller]}_controller".camelize.safe_constantize

            next if controller&.action_methods&.include?(route[:action])

            "#{verb.upcase} #{path} -> #{route[:controller]}##{route[:action]}"
          end
        end

      expect(missing).to be_empty, "documented operations resolve to actions that do not exist: #{missing.join(', ')}"
    end

    # The other half of A-F1: the reference invented four ways to create a
    # template from a file and omitted the one this fork exists to add. These
    # are the doors a paying integrator is sold; dropping one from the document
    # is as bad as inventing one.
    it 'documents every operation an integrator is promised, including this fork\'s own POST /templates' do
      get '/docs/openapi.json'

      documented =
        JSON.parse(response.body).fetch('paths').flat_map do |path, operations|
          operations.keys.map { |verb| "#{verb.upcase} #{path}" }
        end

      expect(documented).to include(
        'POST /templates',            # create a template from a PDF your app generated (this fork)
        'GET /templates',
        'GET /templates/{id}',
        'PUT /templates/{id}',
        'DELETE /templates/{id}',
        'POST /templates/{id}/clone',
        'POST /submissions',          # send it for signing
        'GET /submissions',
        'GET /submissions/{id}',
        'DELETE /submissions/{id}',
        'GET /submissions/{id}/documents',
        'POST /submissions/emails',
        'GET /submitters',
        'GET /submitters/{id}',
        'PUT /submitters/{id}',
        'POST /signing_sessions',     # the embedded doors (this fork)
        'GET /signing_sessions/{id}',
        'POST /template_builder_sessions',
        'GET /template_builder_sessions/{id}',
        'POST /template_preview_sessions',
        'GET /user'                   # the token check
      )
    end

    it 'documents the preview and application palette limits' do
      get '/docs/openapi.json'

      paths = JSON.parse(response.body).fetch('paths')
      builder = paths.dig('/template_builder_sessions', 'post', 'requestBody', 'content',
                          'application/json', 'schema', 'properties', 'custom_fields')
      expect(builder['maxItems']).to eq(Params::TemplateBuilderSessionCreateValidator::MAX_CUSTOM_FIELDS)
      expect(builder.dig('items', 'properties', 'type', 'enum'))
        .to eq(Params::TemplateBuilderSessionCreateValidator::CUSTOM_FIELD_TYPES)
      preview = paths.dig('/template_preview_sessions', 'post', 'requestBody', 'content',
                          'application/json', 'schema')
      expect(preview['required']).to contain_exactly('template_id', 'embed_origin')
      expect(preview.dig('properties', 'values', 'maxProperties'))
        .to eq(Params::TemplatePreviewSessionCreateValidator::MAX_VALUES)
      expect(preview.dig('properties', 'values', 'additionalProperties', 'type')).to eq('string')
    end

    it 'never brings back the upstream operations this fork does not route' do
      get '/docs/openapi.json'

      paths = JSON.parse(response.body).fetch('paths')

      expect(paths.keys).not_to include('/templates/pdf', '/templates/docx', '/templates/html', '/templates/merge',
                                        '/submissions/pdf', '/submissions/docx', '/submissions/html',
                                        '/templates/{id}/documents')
      expect(response.body).not_to include('createTemplateFromPdf')
      expect(response.body).not_to include('mergeTemplate')
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

  # --- review 1 regressions --------------------------------------------------

  describe 'the description is IN the production image (C1)' do
    # Nothing in the runtime stage copies the repository root, so docs/ is in
    # the image only because a line puts it there. Without it PATH.mtime raises
    # Errno::ENOENT on the first request and both /docs/api and
    # /docs/openapi.json are dead on the deployed instance while every test
    # here passes against a checked-out tree.
    let(:dockerfile) { Rails.root.join('Dockerfile').read }

    it 'is copied into the runtime stage' do
      expect(OpenapiDocument::PATH).to exist

      relative = OpenapiDocument::PATH.relative_path_from(Rails.root).to_s
      expect(relative).to eq('docs/openapi.json')

      runtime_stage = dockerfile.split(/^FROM /).last
      copied = runtime_stage.scan(%r{^COPY[^\n]*?\s\./(\S+)}).flatten

      expect(copied).to include(a_string_matching(%r{\Adocs(/openapi\.json)?\z})),
                        'the Dockerfile runtime stage does not COPY docs/openapi.json, so the deployed ' \
                        'image has no API description and /docs/api is dead'
    end
  end

  describe 'a cold process serving several requests at once (H1)' do
    # The cache used to publish the file's mtime BEFORE the value existed, so a
    # second caller arriving in that window was handed a nil and served it with
    # a public, hour-long max-age — an empty API description cached for an hour
    # by every browser and proxy that asked during a deploy.
    #
    # Every ivar the module has ever cached in is cleared, so this describes
    # the behaviour of a cold process rather than the shape of the cache.
    def cold!
      %i[@cache @mtime @json].each do |ivar|
        OpenapiDocument.remove_instance_variable(ivar) if OpenapiDocument.instance_variable_defined?(ivar)
      end
    end

    it 'gives every concurrent caller the real document, never a half-built cache' do
      cold!

      results = Array.new(4).map { Thread.new { OpenapiDocument.json } }.map(&:value)

      expect(results).to all(be_a(String))
      expect(results.map { |json| JSON.parse(json)['openapi'] }).to all(be_present)
    end

    it 'does not mark the cache current when the read fails, so the next request tries again' do
      cold!
      allow(OpenapiDocument).to receive(:document).and_raise(Errno::ENOENT)

      expect { OpenapiDocument.json }.to raise_error(Errno::ENOENT)

      allow(OpenapiDocument).to receive(:document).and_call_original

      expect(JSON.parse(OpenapiDocument.json)['openapi']).to be_present
    end
  end

  describe 'the sample files the document sends developers to (M2)' do
    # The origin rewrite turns the upstream's hosted samples into OUR host, so
    # every one of them has to exist here or the two most-followed
    # getting-started paths in the reference end at a 404 on our own domain.
    it 'serves every example file it links to on this origin' do
      get '/docs/openapi.json'

      linked = response.body.scan(/href=\\?"#{Regexp.escape(OpenapiDocument.app_url)}([^"\\]*)/).flatten.uniq

      expect(linked).not_to be_empty
      linked.each do |path|
        file = Rails.public_path.join(path.delete_prefix('/'))
        routed = begin
          Rails.application.routes.recognize_path(path)
        rescue StandardError
          nil
        end

        expect(file.file? || routed).to be_truthy,
                                        "the served document links to #{path} on our own origin, and nothing " \
                                        'answers there'
      end
    end
  end

  describe 'what the contact block and the introduction say (L2, M3)' do
    let(:info) { JSON.parse(OpenapiDocument.json).fetch('info') }

    it 'publishes the support form and no email address on this public endpoint' do
      expect(info['contact']).not_to have_key('email')
      expect(info['contact']['url']).to eq(OpenapiDocument::CONTACT_URL)
      expect(OpenapiDocument.json).not_to include(Docuseal::SUPPORT_EMAIL)
    end

    it 'introduces the API as a product rather than as an engineering note' do
      # The same list spec/golden/marketing_spec.rb holds the public pages to.
      upstream_phrases = ['a customized fork', 'self-hosted', 'Docker', 'Open Source Document Signing']

      expect(info['description']).to be_present
      upstream_phrases.each do |phrase|
        expect(info['description']).not_to include(phrase), "the API description says #{phrase}"
      end
      expect(info['description']).to include('EsignCenter')
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
