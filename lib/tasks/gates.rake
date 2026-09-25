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
  # The CERTS environment escape hatch is gone (Session 4): a customer signs
  # with the platform certificate and an internal account with its own row, so
  # no code may read a signing identity out of the environment again.
  CERTS_ENV_PATTERNS = [
    /Docuseal::CERTS/,
    /ENV\[['"]CERTS['"]\]/,
    /ENV\.fetch\(['"]CERTS['"]/
  ].freeze
  ISOLATION_PATTERNS = [
    CONFIG_LOOKUP,
    UNSCOPED_CONFIG_ENUMERATION,
    /Account\s*\.\s*order\(\s*:id\s*\)\s*\.\s*(first|take|limit)/m,
    /Account\s*\.\s*(first\b|minimum\(\s*:id\s*\))/m,
    ACCOUNT_ONE_PATTERN,
    /\.order\(\s*:account_id\s*\)/m,
    *CERTS_ENV_PATTERNS
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
  # ---------------------------------------------------------------------------
  # Account-kind gate (REVIEW 4 / S5 carry-over)
  # ---------------------------------------------------------------------------
  # `account_kind` decides what an account IS: a customer that is metered and
  # billed, an internal account that is not, or the platform operator. The
  # column carries a `customer` default, so an account created without naming
  # its kind is silently a paying-plan customer — which is how a provisioning
  # door or a rake task quietly mints a tenant that shows up in the console,
  # counts against nothing, and is billed for by nobody. Every creation site in
  # app/ and lib/ therefore has to say the kind out loud.
  #
  # Multiline-aware like the config-lookup scan: the argument list may run over
  # as many lines as it likes, and `account_kind:` counts wherever it sits
  # inside the call's own parentheses.
  #
  # Every idiom Rails offers for making one, not just the two the first
  # version knew (review 2, M2/M3): `build` and `find_or_create_by` are the
  # commonest of all, `Account.create name: x` needs no parentheses, and a
  # bare `accounts.create!` has no dot in front of it. A gate with holes in
  # the ordinary spellings is worse than no gate, because reviewers stop
  # looking.
  #
  # Review 10 (D-F3) added the rest of the vocabulary, proven by a probe file
  # the gate read and passed: `create_or_find_by` (the find-or-create twin
  # that races on the unique index instead of on the read), and the four bulk
  # writers — `insert`, `insert_all`, `upsert`, `upsert_all` — which matter
  # MORE than the others here, not less: they compile straight to SQL, so the
  # column's `customer` default is applied by Postgres with no model, no
  # validation and no callback anywhere in the path. A row minted that way is
  # a billable tenant nobody named.
  ACCOUNT_CREATION_VERBS = 'new|create_or_find_by!?|create!?|build|find_or_create_by!?|first_or_create!?|' \
                           'insert_all!?|insert!?|upsert_all|upsert'
  # `Account` itself, or an association/local whose name ends in `account(s)`
  # — `user.accounts`, a bare `accounts`, `testing_account`.
  ACCOUNT_RECEIVER = '(?:\bAccount|\b[a-z_]*accounts?)'
  # A relation the creation may be chained off: `Account.where(name: n)
  # .first_or_create!`, `user.accounts.where(...).create!`, `Account.unscoped
  # .new` — which is how `first_or_create` is actually spelled, and how the
  # gate walked past all three until review 2 (N5).
  #
  # A NAMED list, unlike the config-lookup gate's SCOPE_SEGMENT, because the
  # receiver here can be an association: "any method" would read
  # `account.templates.create!(...)` as an account creation.
  #
  # `create_with` is a scope like the others AND it is where the attributes of
  # the creation behind it are written — `Account.create_with(name: n)
  # .find_or_create_by(external_id: id)` — so the kind may honestly be named
  # in that segment rather than in the final call. The whole chain is one
  # match, and ACCOUNT_KIND_ARGUMENT is asked of the whole match, so naming it
  # there passes and naming it nowhere does not (review 10, D-F3).
  ACCOUNT_SCOPE_VERBS = 'where|not|unscoped|all|order|limit|offset|includes|joins|distinct|lock|select|' \
                        'find_by!?|create_with'
  ACCOUNT_SCOPE_SEGMENT =
    "\\s*\\.\\s*(?:#{ACCOUNT_SCOPE_VERBS})(?![\\w!?])(?:\\s*\\(#{CALL_ARGS}\\))?".freeze
  # Parenthesised over as many lines as it likes, or paren-less to the end of
  # the line (`Account.create name: x`, and `Account.new` on its own).
  ACCOUNT_CREATION_CALL =
    "(?:#{ACCOUNT_CREATION_VERBS})(?![\\w!?])(?:\\s*\\(#{CALL_ARGS}\\)|[^\\n]*)".freeze
  ACCOUNT_CREATION = /#{ACCOUNT_RECEIVER}(?:#{ACCOUNT_SCOPE_SEGMENT})*\s*\.\s*#{ACCOUNT_CREATION_CALL}/m
  # `account.dup` is how the tree's only two real creators work. It is its own
  # pattern, with no argument list to look in, so it can only ever pass by
  # being allowlisted — which is the point: somebody has to say out loud that
  # a copy inherits the original's kind.
  ACCOUNT_DUP = /#{ACCOUNT_RECEIVER}\s*\.\s*dup(?![\w!?])/
  ACCOUNT_KIND_ARGUMENT = /\baccount_kind\s*:/
  # Quoted text and comments are not code: `Account.new(name: 'account_kind:')`
  # names no kind, and a snippet inside a comment creates no account. Blanked
  # rather than deleted so every offset still lines up — line numbers and the
  # allowlist's snippet ranges are taken against the same string.
  #
  # Same-line only, and heredoc bodies blanked first (review 2, N6). A quote
  # that runs to the end of the FILE is how the gate fails open: an apostrophe
  # in heredoc prose ("the customer's name") opened a string that swallowed
  # every line up to the next apostrophe, creation sites included, and the
  # gate then reported nothing. A string really spread over two source lines
  # is now left alone instead, which can only ever cost a false alarm.
  CODE_NOISE = /'(?:\\[^\n]|[^'\\\n])*'|"(?:\\[^\n]|[^"\\\n])*"|\#[^\n]*/
  # `X = <<~TAG ... TAG`: the opening line is code and is kept, the body and
  # the terminator are prose and are blanked.
  HEREDOC_BODY = /(<<[-~]?['"]?(\w+)['"]?[^\n]*\n)(.*?)(^[ \t]*\2\b)/m
  # Pinned file AND snippet, exactly like the isolation allowlist: an entry
  # exempts the one expression it names and nothing else on the line.
  ACCOUNT_KIND_ALLOWLIST = [
    {
      file: 'lib/replace_email_variables.rb',
      snippet: 'Account.new(id: submission.account_id)',
      reason: 'unsaved stand-in for an id, never validated or saved: Accounts.link_expires_at reads account_id only'
    },
    {
      file: 'lib/submitters/serialize_for_webhook.rb',
      snippet: 'Account.new(id: submitter.account_id)',
      reason: 'unsaved stand-in for an id, never validated or saved: Accounts.link_expires_at reads account_id only'
    },
    {
      file: 'lib/submitters/serialize_for_api.rb',
      snippet: 'Account.new(id: submitter.account_id)',
      reason: 'unsaved stand-in for an id, never validated or saved: Accounts.link_expires_at reads account_id only'
    },
    {
      file: 'lib/submissions/serialize_for_api.rb',
      snippet: 'Account.new(id: submission.account_id)',
      reason: 'unsaved stand-in for an id, never validated or saved: Accounts.link_expires_at reads account_id only'
    },
    {
      file: 'lib/templates/serialize_for_api.rb',
      snippet: 'Account.new(id: template.account_id)',
      reason: 'unsaved stand-in for an id, never validated or saved: Accounts.link_expires_at reads account_id only'
    },
    {
      file: 'lib/accounts.rb',
      snippet: 'account.dup',
      reason: 'dup copies every attribute of the original, account_kind included, and both sites reassign it ' \
              'explicitly on the next line (create_duplicate, find_or_create_testing_user)'
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
  # The README fork statement is the only place the upstream domain may appear:
  # the AGPL attribution itself points at the upstream *source repository*
  # (Docuseal::DOCUSEAL_SOURCE_URL), so no app file needs the commercial domain
  # and the gate refuses it everywhere else. LICENSE / LICENSE_ADDITIONAL_TERMS
  # are legal text and are not scanned at all.
  BRANDING_ALLOWLIST = [
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
      snippets: ['Docuseal::DOCUSEAL_SOURCE_URL', '>DocuSeal</a>', 'AGPL LICENSE_ADDITIONAL_TERMS'],
      # The anchor has to be rendered markup, not a mention: a line outside any
      # ERB or HTML comment that opens the anchor with the attribution URL.
      rendered_anchor: '<a href="<%= Docuseal::DOCUSEAL_SOURCE_URL'
    },
    {
      # The printed/scanned QR page is an interactive user interface too, and
      # rebranding `product_name` had quietly taken the DocuSeal credit off it:
      # the file still said "Powered by <a>...</a>", but both the wording and
      # the link had become ours. The DocuSeal anchor is pinned here the same
      # way it is in the footer above, so the credit cannot be renamed away a
      # second time.
      file: 'app/views/templates_share_link_qr/_branding.html.erb',
      snippets: ["t('powered_by')", 'Docuseal::PRODUCT_URL', 'Docuseal.product_name',
                 'Docuseal::DOCUSEAL_SOURCE_URL', '>DocuSeal</a>', 'AGPL LICENSE_ADDITIONAL_TERMS'],
      rendered_anchor: '<a href="<%= Docuseal::DOCUSEAL_SOURCE_URL'
    },
    {
      file: 'lib/docuseal.rb',
      snippets: ["DOCUSEAL_SOURCE_URL = 'https://github.com/docusealco/docuseal'",
                 "SUPPORT_EMAIL = 'support@aceddev.com'"]
    }
  ].freeze
  # Keeping the partials alive proves nothing if the pages stop rendering them:
  # deleting `render 'shared/attribution'` from a signer-facing view used to
  # leave this gate green. Every view that carried the attribution when the
  # gate was written is pinned here and must keep a *visible* render call (one
  # parked in an ERB or HTML comment is not a render). Adding a new page is
  # free; dropping the footer from an existing one is not.
  ATTRIBUTION_RENDER_CALLS = ["render 'shared/attribution'", "render 'shared/powered_by'"].freeze
  ATTRIBUTION_RENDER_SITES = %w[
    app/views/embed_template_builder/show.html.erb
    app/views/embed_template_builder/upgrade_required.html.erb
    app/views/layouts/marketing.html.erb
    app/views/send_submission_email/success.html.erb
    app/views/shared/_attribution.html.erb
    app/views/start_form/completed.html.erb
    app/views/start_form/completed_unproven.html.erb
    app/views/start_form/documents_not_ready.html.erb
    app/views/start_form/email_verification.html.erb
    app/views/start_form/email_verification_required.html.erb
    app/views/start_form/paused.html.erb
    app/views/start_form/private.html.erb
    app/views/start_form/show.html.erb
    app/views/submissions_preview/completed.html.erb
    app/views/submit_form/archived.html.erb
    app/views/submit_form/awaiting.html.erb
    app/views/submit_form/completed.html.erb
    app/views/submit_form/declined.html.erb
    app/views/submit_form/delegated.html.erb
    app/views/submit_form/delegation_unavailable.html.erb
    app/views/submit_form/email_2fa.html.erb
    app/views/submit_form/expired.html.erb
    app/views/submit_form/show.html.erb
    app/views/submit_form/success.html.erb
    app/views/verify/show.html.erb
  ].freeze
  # The QR page carries its own branding partial, so it names its own call.
  QR_RENDER_SITE = 'app/views/templates_share_link_qr/show.html.erb'
  QR_RENDER_CALLS = ["render 'branding'"].freeze
  EXPECTED_SUPPORT_EMAIL = 'support@aceddev.com'

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

  # --- account kind -------------------------------------------------------------

  def account_kind_failures
    source_files.flat_map { |path| account_kind_violations(read(path), relative(path)) }
  end

  # Only app/ and lib/ are scanned (source_files also carries config/, which
  # creates no accounts); specs and factories are free to build whatever they
  # like, because a factory's default is a decision somebody made on purpose.
  def account_kind_violations(content, relative_path)
    return [] unless relative_path.start_with?('app/', 'lib/')

    code = blank_code_noise(content)

    unique_matches(code, [ACCOUNT_CREATION, ACCOUNT_DUP]).filter_map do |match|
      next if match[0].match?(ACCOUNT_KIND_ARGUMENT)
      next if allowlisted?(ACCOUNT_KIND_ALLOWLIST, relative_path, content, match)

      "#{format_violation(content, relative_path, match)} [account_kind: is missing]"
    end
  end

  # Strings, heredoc bodies and comments blanked out, character for character,
  # newlines kept (CODE_NOISE, HEREDOC_BODY). Heredocs go first: their bodies
  # are prose, and prose is where the apostrophes are.
  def blank_code_noise(content)
    blank_heredoc_bodies(content).gsub(CODE_NOISE) { |noise| blank_text(noise) }
  end

  def blank_heredoc_bodies(content)
    content.gsub(HEREDOC_BODY) do
      opening, body, terminator = Regexp.last_match.values_at(1, 3, 4)

      "#{opening}#{blank_text(body)}#{blank_text(terminator)}"
    end
  end

  def blank_text(text)
    text.gsub(/[^\n]/, ' ')
  end

  # --- branding ----------------------------------------------------------------

  def branding_failures
    branding_scan_failures + attribution_failures + attribution_render_failures + support_email_failures
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

  # Every pinned view still renders one of the attribution partials.
  def attribution_render_failures(root = ROOT)
    sites = ATTRIBUTION_RENDER_SITES.index_with(ATTRIBUTION_RENDER_CALLS)
                                    .merge(QR_RENDER_SITE => QR_RENDER_CALLS)

    sites.flat_map { |file, calls| render_site_failures(root, file, calls) }
  end

  def render_site_failures(root, file, calls)
    path = File.join(root, file)

    return ["#{file}: attribution render site is missing"] unless File.file?(path)
    return [] if calls.any? { |call| visible_markup(read(path)).include?(call) }

    ["#{file}: attribution partial is no longer rendered (expected #{calls.join(' or ')})"]
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

  desc 'Reject an account created without naming its account_kind'
  task account_kind: :environment do
    failures = Gates.account_kind_failures

    abort "Account-kind gate failed:\n#{failures.join("\n")}" if failures.any?

    puts 'Account-kind gate passed.'
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
    Rake::Task['gates:account_kind'].invoke
    Rake::Task['gates:branding'].invoke
    Gates.run_gate!('Rubocop gate', 'bundle exec rubocop')
    Gates.run_gate!('ERB lint gate', 'bundle exec erb_lint ./app')
    Gates.run_gate!('ESLint gate', './node_modules/eslint/bin/eslint.js "app/javascript/**/*.js"')
    Gates.run_gate!('Brakeman gate', 'bundle exec brakeman -q --exit-on-warn')
  end
end
