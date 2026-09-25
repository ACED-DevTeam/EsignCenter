# frozen_string_literal: true

require 'rake'

Rails.application.load_tasks unless Rake::Task.task_defined?('gates:branding')

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Branding gate' do
  # Every fixture is assembled at runtime: the gate scans spec/ too, so this
  # file must never carry a banned literal of its own.
  def brand(*parts)
    parts.join
  end

  let(:upstream_host) { brand('docuseal', '.com') }
  let(:upstream_short_host) { brand('docuseal', '.co') }
  let(:legacy_host) { brand('vaclaim', 'net') }

  describe 'Gates.branding_violations' do
    it 'catches every banned literal case-insensitively and names it once' do
      fixtures = {
        brand('www.docuseal', '.com/start') => upstream_host,
        brand('DocuSeal', '.CO/start') => upstream_short_host,
        brand('demo.docuseal', '.tech') => brand('docuseal', '.tech'),
        brand('app.vaclaim', 'net.com') => legacy_host,
        brand('Koal', 'ify') => brand('koal', 'ify'),
        brand('esigncenter', '.app') => brand('esigncenter', '.app'),
        brand('support@vaclaim', 'net.com') => brand('support@', legacy_host),
        brand('docuseal/', 'docuseal:latest') => brand('docuseal/', 'docuseal', ' (image ref)')
      }

      fixtures.each do |text, name|
        violations = Gates.branding_violations("clean line\nimage = '#{text}'\n", 'lib/probe.rb')

        expect(violations).to contain_exactly("lib/probe.rb:2: image = '#{text}' [#{name}]"), text
      end
    end

    it 'reports every occurrence, each on its own line' do
      content = "a = '#{upstream_host}'\nb = 'fine'\nc = '#{legacy_host}'\n"

      expect(Gates.branding_violations(content, 'app/models/probe.rb')).to eq(
        [
          "app/models/probe.rb:1: a = '#{upstream_host}' [#{upstream_host}]",
          "app/models/probe.rb:3: c = '#{legacy_host}' [#{legacy_host}]"
        ]
      )
    end

    it 'leaves the product name and the plain DocuSeal word alone' do
      content = "# AGPL: the DocuSeal attribution below must be retained\nDocuseal.product_name\n"

      expect(Gates.branding_violations(content, 'app/views/probe.html.erb')).to be_empty
    end

    # The AGPL attribution points at the upstream SOURCE repository, so no app
    # file needs the commercial domain any more — not even lib/docuseal.rb,
    # which used to be allowlisted for it.
    it 'refuses the upstream domain everywhere in app code, lib/docuseal.rb included' do
      snippet = "DOCUSEAL_URL = 'https://www.#{upstream_host}'"

      expect(Gates.branding_violations("module Docuseal\n  #{snippet}\nend\n", 'lib/docuseal.rb'))
        .to contain_exactly("lib/docuseal.rb:2: #{snippet} [#{upstream_host}]")
      expect(Gates.branding_violations("module Docuseal\n  #{snippet}\nend\n", 'lib/other.rb'))
        .to contain_exactly("lib/other.rb:2: #{snippet} [#{upstream_host}]")
    end

    it 'leaves the source-repo attribution target alone' do
      snippet = "DOCUSEAL_SOURCE_URL = '#{Docuseal::DOCUSEAL_SOURCE_URL}'"

      expect(Gates.branding_violations("module Docuseal\n  #{snippet}\nend\n", 'lib/docuseal.rb')).to be_empty
      expect(Docuseal::DOCUSEAL_SOURCE_URL).to eq('https://github.com/docusealco/docuseal')
    end

    it 'exempts the README fork statement only in README.md' do
      snippet = "EsignCenter is a customized fork of [DocuSeal](https://www.#{upstream_host})"

      expect(Gates.branding_violations("#{snippet}, licensed under the AGPL-3.0.\n", 'README.md')).to be_empty
      expect(Gates.branding_violations("#{snippet}\n", 'docs/readme-copy.md')).to have_attributes(size: 1)
    end

    it 'fails a line that carries an allowlisted snippet plus a second banned literal' do
      line = "EsignCenter is a customized fork of [DocuSeal](https://www.#{upstream_host}) " \
             "— see #{upstream_short_host}/start"

      expect(Gates.branding_violations("#{line}\n", 'README.md'))
        .to contain_exactly("README.md:1: #{line} [#{upstream_short_host}]")
    end

    it 'does not exempt a partial rewrite of the allowlisted snippet' do
      line = "EsignCenter is a fork of [DocuSeal](https://www.#{upstream_host})"

      expect(Gates.branding_violations("#{line}\n", 'README.md'))
        .to contain_exactly("README.md:1: #{line} [#{upstream_host}]")
    end
  end

  describe 'Gates.attribution_failures' do
    let(:powered_by_file) { 'app/views/shared/_powered_by.html.erb' }
    let(:rendered_anchor) do
      '<a href="<%= Docuseal::DOCUSEAL_SOURCE_URL %>" target="_blank" rel="noopener" class="underline">DocuSeal</a>'
    end

    # A minimal passing file: every required snippet plus, where the
    # requirement asks for one, the anchor as real rendered markup.
    def passing_content(requirement)
      lines = requirement.fetch(:snippets).dup
      lines << rendered_anchor if requirement[:rendered_anchor]

      lines.join("\n")
    end

    def write_tree(root, overrides = {})
      Gates::ATTRIBUTION_REQUIREMENTS.each do |requirement|
        path = File.join(root, requirement.fetch(:file))
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, overrides.fetch(requirement.fetch(:file), passing_content(requirement)))
      end
    end

    # A throwaway tree with every attribution file written, the given files
    # replaced, and any last edit the example needs applied to `root`.
    def attribution_failures_for(overrides = {})
      Dir.mktmpdir do |root|
        write_tree(root, overrides)
        yield root if block_given?

        Gates.attribution_failures(root)
      end
    end

    it 'passes a tree that carries every required attribution snippet' do
      expect(attribution_failures_for).to be_empty
    end

    it 'fails when the DocuSeal anchor, the constant reference or the AGPL comment disappears' do
      expect(attribution_failures_for(powered_by_file => "<%= t('powered_by') %>\n")).to contain_exactly(
        "#{powered_by_file}: attribution snippet missing: Docuseal::DOCUSEAL_SOURCE_URL",
        "#{powered_by_file}: attribution snippet missing: >DocuSeal</a>",
        "#{powered_by_file}: attribution snippet missing: AGPL LICENSE_ADDITIONAL_TERMS",
        "#{powered_by_file}: attribution anchor is not rendered markup: <a href=\"<%= Docuseal::DOCUSEAL_SOURCE_URL"
      )
    end

    # ERB closes a comment at the first `%>`, so the `<%= … %>` inside the
    # anchor ends the comment early and the tail ("…>DocuSeal</a> %>") is
    # emitted as literal text — the gate mirrors that: the constant is inside
    # the comment (missing), the anchor is not rendered, the tail is visible.
    it 'fails when the DocuSeal anchor survives only inside an ERB comment' do
      commented = "<%# AGPL LICENSE_ADDITIONAL_TERMS: #{rendered_anchor} %>\n<%= t('powered_by') %>\n"

      expect(attribution_failures_for(powered_by_file => commented)).to contain_exactly(
        "#{powered_by_file}: attribution snippet missing: Docuseal::DOCUSEAL_SOURCE_URL",
        "#{powered_by_file}: attribution anchor is not rendered markup: <a href=\"<%= Docuseal::DOCUSEAL_SOURCE_URL"
      )
    end

    # The most realistic evasion: the anchor line wrapped in an HTML comment.
    # The browser never renders it, so neither the anchor nor the snippets
    # inside it count as attribution.
    it 'fails when the DocuSeal anchor survives only inside an HTML comment' do
      commented = "<%# AGPL LICENSE_ADDITIONAL_TERMS: keep the attribution %>\n" \
                  "<!-- #{rendered_anchor} -->\n<%= t('powered_by') %>\n"

      expect(attribution_failures_for(powered_by_file => commented)).to contain_exactly(
        "#{powered_by_file}: attribution snippet missing: Docuseal::DOCUSEAL_SOURCE_URL",
        "#{powered_by_file}: attribution snippet missing: >DocuSeal</a>",
        "#{powered_by_file}: attribution anchor is not rendered markup: <a href=\"<%= Docuseal::DOCUSEAL_SOURCE_URL"
      )
    end

    it 'fails when the QR branding snippets survive only inside an HTML comment' do
      branding_file = 'app/views/templates_share_link_qr/_branding.html.erb'
      requirement = Gates::ATTRIBUTION_REQUIREMENTS.find { |r| r.fetch(:file) == branding_file }
      commented = "<!--\n#{passing_content(requirement)}\n-->\n"

      # The AGPL marker is a developer-facing ERB comment and is looked for in
      # the raw file, so it is the one snippet an HTML comment cannot hide;
      # every visible snippet is missing, and the DocuSeal anchor — pinned on
      # this page since the rebrand hollowed its credit out — is not rendered.
      hidden = requirement.fetch(:snippets).reject { |snippet| snippet.start_with?(Gates::AGPL_MARKER_PREFIX) }

      expect(attribution_failures_for(branding_file => commented)).to contain_exactly(
        *hidden.map { |snippet| "#{branding_file}: attribution snippet missing: #{snippet}" },
        "#{branding_file}: attribution anchor is not rendered markup: #{requirement.fetch(:rendered_anchor)}"
      )
    end

    it 'fails when the constant is mentioned but the anchor is not an href on it' do
      mention = "<%# AGPL LICENSE_ADDITIONAL_TERMS %>\n<%= link_to 'DocuSeal', Docuseal::DOCUSEAL_SOURCE_URL %>\n" \
                "<span>>DocuSeal</a></span>\n"

      expect(attribution_failures_for(powered_by_file => mention)).to contain_exactly(
        "#{powered_by_file}: attribution anchor is not rendered markup: <a href=\"<%= Docuseal::DOCUSEAL_SOURCE_URL"
      )
    end

    it 'fails when an attribution file is missing' do
      missing = 'app/views/templates_share_link_qr/_branding.html.erb'
      failures = attribution_failures_for { |root| FileUtils.rm(File.join(root, missing)) }

      expect(failures).to contain_exactly("#{missing}: attribution file is missing")
    end

    describe 'Gates.rendered?' do
      it 'is true for the anchor as plain markup and false inside an ERB or HTML comment, single- or multi-line' do
        expect(Gates.rendered?("<div>\n  #{rendered_anchor}\n</div>\n", rendered_anchor)).to be(true)
        expect(Gates.rendered?("<%# #{rendered_anchor} %>\n", rendered_anchor)).to be(false)
        expect(Gates.rendered?("<!-- #{rendered_anchor} -->\n", rendered_anchor)).to be(false)
        expect(Gates.rendered?("<!--\n  #{rendered_anchor}\n-->\n", rendered_anchor)).to be(false)
        expect(Gates.rendered?("<%#\n  #{rendered_anchor}\n%>\n", rendered_anchor)).to be(false)
      end

      it 'still sees an anchor that follows a closed comment on the same line' do
        expect(Gates.rendered?("<!-- note --> #{rendered_anchor}\n", rendered_anchor)).to be(true)
      end
    end

    it 'pins the support email constant' do
      expect(Gates.support_email_failures).to be_empty
      expect(Docuseal::SUPPORT_EMAIL).to eq('support@aceddev.com')
    end
  end

  # A2: the partials surviving is worth nothing if the pages stop rendering
  # them. Deleting `render 'shared/attribution'` from a signer-facing view used
  # to leave the whole branding gate green.
  describe 'Gates.attribution_render_failures' do
    def write_render_tree(root, overrides = {})
      sites = Gates::ATTRIBUTION_RENDER_SITES.index_with("<%= #{Gates::ATTRIBUTION_RENDER_CALLS.first} %>")
      sites[Gates::QR_RENDER_SITE] = "<%= #{Gates::QR_RENDER_CALLS.first} %>"

      sites.merge(overrides).each do |file, content|
        path = File.join(root, file)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{content}\n")
      end
    end

    def render_failures_for(overrides = {})
      Dir.mktmpdir do |root|
        write_render_tree(root, overrides)
        yield root if block_given?

        Gates.attribution_render_failures(root)
      end
    end

    it 'pins every view that renders an attribution partial today' do
      live = Rails.root.glob('app/views/**/*.erb').select do |path|
        Gates::ATTRIBUTION_RENDER_CALLS.any? { |call| path.read.include?(call) }
      end
      live = live.map { |path| path.relative_path_from(Rails.root).to_s } - ['app/views/shared/_powered_by.html.erb']

      expect(live.sort).to eq(Gates::ATTRIBUTION_RENDER_SITES.sort)
    end

    it 'passes the real tree' do
      expect(Gates.attribution_render_failures).to be_empty
    end

    it 'passes a tree where every pinned view renders a partial' do
      expect(render_failures_for).to be_empty
    end

    it 'accepts either partial at a shared render site' do
      site = Gates::ATTRIBUTION_RENDER_SITES.first

      expect(render_failures_for(site => "<%= #{Gates::ATTRIBUTION_RENDER_CALLS.last} %>")).to be_empty
    end

    it 'fails when a signer-facing view drops the render call' do
      site = 'app/views/submit_form/completed.html.erb'

      expect(render_failures_for(site => '<p>Document has been signed!</p>')).to contain_exactly(
        "#{site}: attribution partial is no longer rendered " \
        "(expected #{Gates::ATTRIBUTION_RENDER_CALLS.join(' or ')})"
      )
    end

    it 'does not count a render call parked in an ERB or HTML comment' do
      erb = 'app/views/submit_form/declined.html.erb'
      html = 'app/views/submit_form/expired.html.erb'
      call = Gates::ATTRIBUTION_RENDER_CALLS.first

      failures = render_failures_for(erb => "<%# <%= #{call} %> %>", html => "<!-- <%= #{call} %> -->")

      expect(failures.map { |failure| failure.split(':').first }).to contain_exactly(erb, html)
    end

    it 'fails when the QR page stops rendering its branding partial' do
      site = Gates::QR_RENDER_SITE

      expect(render_failures_for(site => '<div class="qr-branding"></div>')).to contain_exactly(
        "#{site}: attribution partial is no longer rendered (expected #{Gates::QR_RENDER_CALLS.join(' or ')})"
      )
    end

    it 'fails when a pinned view is deleted outright' do
      site = 'app/views/verify/show.html.erb'
      failures = render_failures_for { |root| FileUtils.rm(File.join(root, site)) }

      expect(failures).to contain_exactly("#{site}: attribution render site is missing")
    end
  end

  describe 'the current tree' do
    it 'scans specs and never the gate definition or compiled packs' do
      files = Gates.branding_files.map { |path| Gates.relative(path) }

      expect(files).to include('spec/gates/branding_gate_spec.rb', 'README.md', 'SECURITY.md', 'docker-compose.yml')
      expect(files).not_to include(Gates::SELF_PATH)
      expect(files.grep(%r{\Apublic/packs})).to be_empty
    end

    it 'passes the branding gate' do
      expect(Gates.branding_failures).to be_empty
    end
  end
end
# rubocop:enable RSpec/DescribeClass
