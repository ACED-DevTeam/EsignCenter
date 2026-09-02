# frozen_string_literal: true

# CI gates. Every check is a pure function over (content, relative path) so
# spec/gates/*_spec.rb can prove each banned pattern is caught and each
# allowlist entry exempts only its own snippet, without touching the tree.
module Gates
  ROOT = File.expand_path('../..', __dir__)
  # This file is the gate definition: it necessarily spells out every banned
  # pattern and every allowlisted snippet, so it never scans itself.
  SELF_PATH = 'lib/tasks/gates.rake'

  # ---------------------------------------------------------------------------
  # Isolation gate
  # ---------------------------------------------------------------------------
  ACCOUNT_ONE_PATTERN = Regexp.new(['\\baccount(_id)?\\s*', '==\\s*', '1\\b'].join)
  CONFIG_MODELS = '(?:EncryptedConfig|AccountConfig)'
  CONFIG_FINDERS = 'find_by!?|exists\?|where|order|pluck|pick|take|first_or_initialize|' \
                   'find_or_initialize_by|find_or_create_by!?|create_or_find_by!?'
  # Dynamic finders spell the key in the method name (`find_by_key`,
  # `find_by_key!`, `find_by_value_and_key`).
  DYNAMIC_KEY_FINDER = 'find_by_(?:\w+_and_)?key(?:_and_\w+)?!?'
  # An argument list with up to two levels of nested parentheses; `[^()]`
  # matches newlines, so a call split across lines is still one call.
  INNER_ARGS = '(?:[^()]|\([^()]*\))*'
  CALL_ARGS = "(?:[^()]|\\(#{INNER_ARGS}\\))*".freeze
  # One chained scope between the model and the finder — `.unscoped`,
  # `.where(...)`, `.order(...)` — with or without an argument list.
  SCOPE_SEGMENT = "\\s*\\.\\s*\\w+[!?]?(?:\\s*\\(#{CALL_ARGS}\\))?".freeze
  # A finder call: parenthesised, or paren-less to the end of the line.
  FINDER_CALL = "(?:#{CONFIG_FINDERS})(?![\\w!?])(?:\\s*\\(#{CALL_ARGS}\\)|[ \\t]+[^\\n]*)".freeze
  DYNAMIC_FINDER_CALL = "#{DYNAMIC_KEY_FINDER}(?![\\w!?])(?:\\s*\\(#{CALL_ARGS}\\)|[ \\t]+[^\\n]*)?".freeze
  # Every config lookup: the model, any chained scopes, then a finder. Whether
  # it is scoped is decided over the WHOLE expression (unscoped_config_lookup?),
  # so `account:` may sit in any segment of the chain — a lookup carrying
  # `key:` anywhere without an `account:` / `account_id:` alongside it reads
  # whichever account's row happens to come first.
  CONFIG_LOOKUP = /#{CONFIG_MODELS}(?:#{SCOPE_SEGMENT})*\s*\.\s*(?:#{FINDER_CALL}|#{DYNAMIC_FINDER_CALL})/m
  ACCOUNT_SCOPED_ARGUMENT = /\baccount(?:_id)?\s*:|find_by_\w*account/
  KEYED_LOOKUP = /\bkey\s*:|\b#{DYNAMIC_KEY_FINDER}/
  # Enumerating a config table with no arguments at all is unscoped by
  # definition.
  UNSCOPED_CONFIG_ENUMERATION = /#{CONFIG_MODELS}\s*\.\s*(?:first|take|all|pluck|find_each|each)\b/
  ISOLATION_PATTERNS = [
    CONFIG_LOOKUP,
    UNSCOPED_CONFIG_ENUMERATION,
    /Account\s*\.\s*order\(\s*:id\s*\)\s*\.\s*(first|take|limit)/m,
    /Account\s*\.\s*(first\b|minimum\(\s*:id\s*\))/m,
    ACCOUNT_ONE_PATTERN,
    /\.order\(\s*:account_id\s*\)/m
  ].freeze
  # Allowlist entries pin a file AND the exact snippet. A match is exempt only
  # when it falls inside an occurrence of that snippet, so a second forbidden
  # expression on the same line still fails. Adding an entry needs a written
  # reason; the spec-permitted operator-config pins are the only two.
  ISOLATION_ALLOWLIST = [
    {
      file: 'lib/tasks/operator.rake',
      snippet: "AccountConfig.where(key: 'fulltext_search', value: true)",
      reason: 'one-time legacy global adoption in operator:seed'
    },
    {
      file: 'lib/storage_config_guard.rb',
      snippet: 'EncryptedConfig.exists?(key: EncryptedConfig::FILES_STORAGE_KEY)',
      reason: 'boot-time inventory across all accounts (row existence only, no value is read or resolved)'
    }
  ].freeze
  # `multitenant: true` example metadata is banned in every spec: the suite
  # exercises the shipped single-tenant configuration.
  SPEC_METADATA_PATTERN = /multitenant:\s*true/
  # The golden specs may not even mention multitenancy: no metadata, no stub
  # (however it is spelled or split across lines), no constant, no ENV read.
  GOLDEN_BAN_PATTERN = /multitenant\?|MULTITENANT|receive_messages\(\s*multitenant/
  GOLDEN_SPEC_PREFIX = 'spec/golden/'
  SPEC_METADATA_EXEMPT = ['spec/rails_helper.rb'].freeze

  # ---------------------------------------------------------------------------
  # Branding gate
  # ---------------------------------------------------------------------------
  BRANDING_SCAN_GLOBS = [
    '{app,lib,config,docs,public,spec}/**/*',
    'README.md',
    'SECURITY.md',
    'docker-compose*.yml',
    'Dockerfile*',
    '.github/**/*.yml'
  ].freeze
  BRANDING_SCAN_EXCLUDED_PREFIXES = %w[public/packs public/assets].freeze
  # Case-insensitive. Longest-first so an occurrence is reported once under
  # its most specific name (support@vaclaimnet before vaclaimnet).
  BANNED_LITERALS = [
    { name: 'support@vaclaimnet', pattern: /support@vaclaimnet/i },
    { name: 'docuseal/docuseal (image ref)', pattern: %r{docuseal/docuseal}i },
    { name: 'esigncenter.app', pattern: /esigncenter\.app/i },
    { name: 'docuseal.tech', pattern: /docuseal\.tech/i },
    { name: 'docuseal.com', pattern: /docuseal\.com/i },
    { name: 'docuseal.co', pattern: /docuseal\.co\b/i },
    { name: 'vaclaimnet', pattern: /vaclaimnet/i },
    { name: 'koalify', pattern: /koalify/i }
  ].freeze
  # The AGPL attribution target and the README fork statement are the only
  # places the upstream domain may appear. LICENSE / LICENSE_ADDITIONAL_TERMS
  # are legal text and are not scanned at all.
  BRANDING_ALLOWLIST = [
    {
      file: 'lib/docuseal.rb',
      snippet: "DOCUSEAL_URL = 'https://www.docuseal.com'",
      reason: 'AGPL LICENSE_ADDITIONAL_TERMS attribution target'
    },
    {
      file: 'README.md',
      snippet: 'EsignCenter is a customized fork of [DocuSeal](https://www.docuseal.com)',
      reason: 'fork attribution statement'
    }
  ].freeze
  # The gate fails when the attribution disappears, not only when a banned
  # literal appears: these snippets must survive in these files. Both halves
  # of the branding gate are literal substring scans, not semantic ones: the
  # ban catches a literal spelled out in source (not one assembled at runtime
  # or percent-encoded), and the survival check looks for the snippets outside
  # ERB and HTML comments (a commented-out attribution is not attribution).
  ATTRIBUTION_REQUIREMENTS = [
    {
      file: 'app/views/shared/_powered_by.html.erb',
      snippets: ['Docuseal::DOCUSEAL_URL', '>DocuSeal</a>', 'AGPL LICENSE_ADDITIONAL_TERMS'],
      # The anchor has to be rendered markup, not a mention: a line outside any
      # ERB or HTML comment that opens the anchor with the attribution URL.
      rendered_anchor: '<a href="<%= Docuseal::DOCUSEAL_URL'
    },
    {
      file: 'app/views/templates_share_link_qr/_branding.html.erb',
      snippets: ["t('powered_by')", 'Docuseal::PRODUCT_URL', 'Docuseal.product_name']
    },
    {
      file: 'lib/docuseal.rb',
      snippets: ["DOCUSEAL_URL = 'https://www.docuseal.com'", "SUPPORT_EMAIL = 'evan@processorteam.com'"]
    }
  ].freeze
  EXPECTED_SUPPORT_EMAIL = 'evan@processorteam.com'

  module_function

  # --- isolation ---------------------------------------------------------------

  def isolation_failures
    source_failures + spec_failures
  end

  def source_failures
    source_files.flat_map { |path| isolation_violations(read(path), relative(path)) }
  end

  def spec_failures
    spec_files.flat_map { |path| spec_violations(read(path), relative(path)) }
  end

  # Every occurrence is reported, not just the first: a file with one
  # allowlisted expression must still fail on a second, unreviewed one. An
  # expression two patterns both catch is reported once.
  def isolation_violations(content, relative_path)
    unique_matches(content, ISOLATION_PATTERNS) { |match| isolation_violation?(match) }.filter_map do |match|
      next if allowlisted?(ISOLATION_ALLOWLIST, relative_path, content, match)

      format_violation(content, relative_path, match)
    end
  end

  # A config lookup is a violation only when it is keyed and nothing in the
  # whole chain scopes it to an account; every other pattern is a violation
  # wherever it matches.
  def isolation_violation?(match)
    return true unless match.regexp == CONFIG_LOOKUP

    unscoped_config_lookup?(match[0])
  end

  def unscoped_config_lookup?(expression)
    expression.match?(KEYED_LOOKUP) && !expression.match?(ACCOUNT_SCOPED_ARGUMENT)
  end

  def spec_violations(content, relative_path)
    return [] if SPEC_METADATA_EXEMPT.include?(relative_path)

    patterns = [SPEC_METADATA_PATTERN]
    patterns << GOLDEN_BAN_PATTERN if relative_path.start_with?(GOLDEN_SPEC_PREFIX)

    patterns.flat_map do |pattern|
      scan_matches(content, pattern).map { |match| format_violation(content, relative_path, match) }
    end
  end

  # --- branding ----------------------------------------------------------------

  def branding_failures
    branding_scan_failures + attribution_failures + support_email_failures
  end

  def branding_scan_failures
    branding_files.flat_map { |path| branding_violations(read(path), relative(path)) }
  end

  def branding_violations(content, relative_path)
    names = BANNED_LITERALS.to_h { |literal| [literal.fetch(:pattern), literal.fetch(:name)] }

    unique_matches(content, names.keys).filter_map do |match|
      next if allowlisted?(BRANDING_ALLOWLIST, relative_path, content, match)

      "#{format_violation(content, relative_path, match)} [#{names.fetch(match.regexp)}]"
    end
  end

  def attribution_failures(root = ROOT)
    ATTRIBUTION_REQUIREMENTS.flat_map do |requirement|
      file = requirement.fetch(:file)
      path = File.join(root, file)

      next ["#{file}: attribution file is missing"] unless File.file?(path)

      content = read(path)
      visible = visible_markup(content)

      # The AGPL marker is an ERB comment by design and is looked for in the
      # raw file; every other snippet is attribution only when it is visible
      # markup, so a copy parked inside an ERB or HTML comment does not count.
      failures = requirement.fetch(:snippets).reject do |snippet|
        (snippet.start_with?(AGPL_MARKER_PREFIX) ? content : visible).include?(snippet)
      end
      failures = failures.map { |snippet| "#{file}: attribution snippet missing: #{snippet}" }

      anchor = requirement[:rendered_anchor]

      if anchor && !rendered?(content, anchor)
        failures << "#{file}: attribution anchor is not rendered markup: #{anchor}"
      end

      failures
    end
  end

  ERB_COMMENT = /<%#.*?%>/m
  HTML_COMMENT = /<!--.*?-->/m
  AGPL_MARKER_PREFIX = 'AGPL LICENSE_ADDITIONAL_TERMS'

  # The file with every ERB comment and every HTML comment removed: what the
  # browser can actually render. This is a literal substring scan, not a
  # semantic one — it does not evaluate ERB, so an anchor assembled at runtime
  # from pieces would pass; the gate is a tripwire for the realistic evasions
  # (deleting the line, or commenting it out either way).
  def visible_markup(content)
    content.gsub(ERB_COMMENT, '').gsub(HTML_COMMENT, '')
  end

  # True when some line outside every ERB and HTML comment carries the snippet.
  def rendered?(content, snippet)
    visible_markup(content).lines.any? { |line| line.include?(snippet) }
  end

  def support_email_failures
    return [] if defined?(Docuseal::SUPPORT_EMAIL) && Docuseal::SUPPORT_EMAIL == EXPECTED_SUPPORT_EMAIL

    ["Docuseal::SUPPORT_EMAIL must be #{EXPECTED_SUPPORT_EMAIL}"]
  end

  # --- shared ------------------------------------------------------------------

  def scan_matches(content, pattern)
    content.to_enum(:scan, pattern).map { Regexp.last_match }
  end

  # Matches of every pattern, in pattern order, dropping any match that
  # overlaps one already collected — so one expression is reported once even
  # when two patterns both catch it.
  # An optional block filters candidate matches before the overlap check, so
  # a discarded candidate never shadows a real violation on the same span.
  def unique_matches(content, patterns)
    patterns.each_with_object([]) do |pattern, collected|
      scan_matches(content, pattern).each do |match|
        next if block_given? && !yield(match)
        next if collected.any? { |seen| overlap?(seen, match) }

        collected << match
      end
    end
  end

  def overlap?(left, right)
    left.begin(0) < right.end(0) && right.begin(0) < left.end(0)
  end

  # An entry exempts one reviewed expression, never the whole file or line:
  # the match has to sit inside an occurrence of the allowlisted snippet.
  def allowlisted?(allowlist, relative_path, content, match)
    allowlist.any? do |entry|
      next false unless entry.fetch(:file) == relative_path

      snippet_ranges(content, entry.fetch(:snippet)).any? do |range|
        range.cover?(match.begin(0)) && range.cover?(match.end(0) - 1)
      end
    end
  end

  def snippet_ranges(content, snippet)
    ranges = []
    index = content.index(snippet)

    while index
      ranges << (index...(index + snippet.length))
      index = content.index(snippet, index + 1)
    end

    ranges
  end

  def format_violation(content, relative_path, match)
    line_number = content[0...match.begin(0)].count("\n") + 1
    line = content.lines[line_number - 1].to_s.strip

    "#{relative_path}:#{line_number}: #{line}"
  end

  def source_files
    Dir.glob(File.join(ROOT, '{app,lib,config}', '**', '*.{rb,rake,erb}'))
       .reject { |path| relative(path) == SELF_PATH }
       .sort
  end

  def spec_files
    Dir.glob(File.join(ROOT, 'spec', '**', '*')).select { |path| File.file?(path) }.sort
  end

  def branding_files
    BRANDING_SCAN_GLOBS.flat_map { |glob| Dir.glob(File.join(ROOT, glob)) }
                       .select { |path| File.file?(path) }
                       .map { |path| relative(path) }
                       .reject { |file| file == SELF_PATH }
                       .reject { |file| BRANDING_SCAN_EXCLUDED_PREFIXES.any? { |prefix| file.start_with?(prefix) } }
                       .uniq
                       .sort
                       .map { |file| File.join(ROOT, file) }
                       .reject { |path| binary?(path) }
  end

  def binary?(path)
    File.binread(path, 8_000).to_s.include?("\0")
  end

  def read(path)
    File.binread(path).force_encoding(Encoding::UTF_8).scrub
  end

  def relative(path)
    path.delete_prefix("#{ROOT}/")
  end

  def run_gate!(name, command)
    Rake::FileUtilsExt.sh(command)
  rescue RuntimeError
    abort "#{name} failed"
  end
end

namespace :gates do
  desc 'Reject tenant-isolation leak patterns and banned spec metadata'
  task isolation: :environment do
    failures = Gates.isolation_failures

    abort "Isolation gate failed:\n#{failures.join("\n")}" if failures.any?

    puts 'Isolation gate passed.'
  end

  desc 'Reject leftover upstream/legacy brand literals and prove the DocuSeal attribution survives'
  task branding: :environment do
    failures = Gates.branding_failures

    abort "Branding gate failed:\n#{failures.join("\n")}" if failures.any?

    puts 'Branding gate passed.'
  end

  desc 'Run all CI gates'
  task all: :environment do
    Rake::Task['gates:isolation'].invoke
    Rake::Task['gates:branding'].invoke
    Gates.run_gate!('Rubocop gate', 'bundle exec rubocop')
    Gates.run_gate!('ERB lint gate', 'bundle exec erb_lint ./app')
    Gates.run_gate!('ESLint gate', './node_modules/eslint/bin/eslint.js "app/javascript/**/*.js"')
    Gates.run_gate!('Brakeman gate', 'bundle exec brakeman -q --exit-on-warn')
  end
end
