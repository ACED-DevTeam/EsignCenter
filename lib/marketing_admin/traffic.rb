# frozen_string_literal: true

module MarketingAdmin
  # The website counter behind the "Website" section of /admin.
  #
  # First-party and server-side: the app that renders a public page adds one
  # to a counter for (day, page, where the visit came from, campaign tag,
  # device type). That is all that is kept. No cookie is set, no IP address
  # is stored, no visitor is given an id, nothing is sent to a third party,
  # and the referring address is thrown away as soon as it has been sorted
  # into one of a dozen labels ("Google", "Reddit", "another website").
  #
  # What it deliberately cannot answer: how many PEOPLE visited, whether two
  # views were the same person, or what one visitor did next. It counts page
  # views, not visitors.
  module Traffic
    EVENTS = [
      VIEW = 'view',
      # Somebody opened the sign-up page: what a click on "Start free" leads
      # to. Its `path` is the page the click happened on, not /sign_up.
      SIGNUP_OPEN = 'signup_open',
      # A sign-up that went through. Counted per campaign tag, never stored
      # against the account that was created.
      SIGNUP = 'signup'
    ].freeze

    SOURCES = {
      'google' => 'Google',
      'facebook' => 'Facebook',
      'instagram' => 'Instagram',
      'youtube' => 'YouTube',
      'tiktok' => 'TikTok',
      'reddit' => 'Reddit',
      'chatgpt' => 'ChatGPT',
      'linkedin' => 'LinkedIn',
      'email' => 'Email',
      'direct' => 'Direct or unknown',
      'internal' => 'Another EsignCenter page',
      'other' => 'Other websites'
    }.freeze

    DEVICES = {
      'mobile' => 'Phone',
      'tablet' => 'Tablet',
      'desktop' => 'Computer',
      'unknown' => 'Unknown'
    }.freeze

    # The Chore Lock-style tags the social posts carry in their links:
    # ?ct=yt-<slug> is a YouTube video, ?ct=rd-<slug> a Reddit comment.
    TAG_PREFIXES = {
      'yt' => 'youtube', 'tt' => 'tiktok', 'ig' => 'instagram',
      'fb' => 'facebook', 'rd' => 'reddit', 'em' => 'email'
    }.freeze

    UTM_SOURCES = {
      'google' => 'google',
      'facebook' => 'facebook', 'fb' => 'facebook', 'meta' => 'facebook',
      'instagram' => 'instagram', 'ig' => 'instagram',
      'youtube' => 'youtube', 'yt' => 'youtube',
      'tiktok' => 'tiktok', 'tt' => 'tiktok',
      'reddit' => 'reddit',
      'chatgpt' => 'chatgpt', 'chatgpt.com' => 'chatgpt', 'openai' => 'chatgpt',
      'linkedin' => 'linkedin',
      'email' => 'email', 'newsletter' => 'email', 'mail' => 'email'
    }.freeze

    # Checked in this order: webmail first, so mail.google.com is "Email"
    # before the Google rule can call it a search.
    REFERRER_HOSTS = {
      'email' => /\A(mail\.google\.com|outlook\.(live|office|office365)\.com|mail\.yahoo\.com|mail\.proton\.me|
                    mail\.aol\.com|app\.fastmail\.com)\z/x,
      'google' => /(\A|\.)google\.[a-z]{2,3}(\.[a-z]{2})?\z/,
      'facebook' => /(\A|\.)(facebook\.com|fb\.com|fb\.me|messenger\.com)\z/,
      'instagram' => /(\A|\.)instagram\.com\z/,
      'youtube' => /(\A|\.)(youtube\.com|youtu\.be)\z/,
      'tiktok' => /(\A|\.)tiktok\.com\z/,
      'reddit' => /(\A|\.)(reddit\.com|redd\.it)\z/,
      'chatgpt' => /(\A|\.)(chatgpt\.com|openai\.com)\z/,
      'linkedin' => /(\A|\.)(linkedin\.com|lnkd\.in)\z/
    }.freeze

    # Phone apps that open links announce themselves with an android-app://
    # address instead of a web one.
    ANDROID_APPS = {
      'com.google.android.gm' => 'email',
      'com.google.android.googlequicksearchbox' => 'google',
      'com.facebook.katana' => 'facebook',
      'com.instagram.android' => 'instagram',
      'com.google.android.youtube' => 'youtube',
      'com.zhiliaoapp.musically' => 'tiktok',
      'com.reddit.frontpage' => 'reddit',
      'com.linkedin.android' => 'linkedin'
    }.freeze

    # A campaign tag is kept only when it looks like one of ours: lowercase
    # letters, digits, dashes and underscores, 48 characters at most. Anything
    # else in the address is dropped, so nothing a stranger types into a link
    # is ever stored.
    CAMPAIGN_FORMAT = /\A[a-z0-9][a-z0-9_-]{0,47}\z/

    # A stranger could still invent tags that fit the format. Past this many
    # different tags in one day the rest are counted together, so the table
    # cannot be grown without limit from the outside.
    MAX_CAMPAIGNS_PER_DAY = 100
    OVERFLOW_CAMPAIGN = '~more'

    # The origin page recorded for a sign-up page that was opened from
    # somewhere other than one of our own counted pages.
    ELSEWHERE_PATH = '(elsewhere)'
    SIGNUP_PATH = '/sign_up'

    # Software that fetches pages without a person reading them: search and
    # AI crawlers, link previews in chat apps, uptime checks, scripts. A
    # heuristic, and it errs towards not counting.
    BOT_PATTERN = %r{
      bot|crawl|spider|slurp|scrape|headless|phantom|lighthouse|pagespeed|preview|fetch|monitor|uptime|
      pingdom|statuscake|datadog|newrelic|curl|wget|httpie|python|ruby|java/|go-http|okhttp|axios|
      undici|libwww|scrapy|postman|insomnia|facebookexternalhit|whatsapp|embedly|chatgpt-user|
      claude|anthropic|perplexity|mediapartners|google-inspectiontool|googleother|apis-google
    }ix

    PREFETCH_HEADERS = %w[HTTP_PURPOSE HTTP_SEC_PURPOSE HTTP_X_PURPOSE HTTP_X_MOZ HTTP_X_SEC_PURPOSE].freeze

    Origin = Struct.new(:source, :campaign)

    # The pages a view can be filed under. A finite list on purpose: the page
    # a visit is counted against is the one thing in a row that comes from an
    # ADDRESS, and an address can carry anything — an invitation link's secret
    # token, a document's slug, whatever a stranger types. So no address is
    # ever stored as it arrived: it is matched against this list (and the help
    # centre's own list of articles) and everything else is one row,
    # ELSEWHERE_PATH. That also puts a ceiling on how many rows a day can have.
    PUBLIC_PATHS = %w[/ /pricing /trust /trust/subprocessors /terms /privacy /help /support /docs/api].freeze
    HELP_ARTICLE_PREFIX = '/help/'

    # Anything longer than these is not one of ours and is not looked at.
    MAX_TAG_BYTES = 96
    MAX_QUERY_BYTES = 2048

    # Where the decided tally waits between the controller, which knows what
    # was asked for, and MarketingPageViewsMiddleware, which knows what was
    # finally sent (a conditional GET can still turn a 200 into a 304).
    ENV_KEY = 'esigncenter.marketing_tally'

    # How long one tally may wait on the database before it is dropped. A
    # counter is never worth a visitor's time: a page view that cannot be
    # written at once is simply not counted.
    LOCK_BUDGET_MS = 50
    STATEMENT_BUDGET_MS = 200

    # The two-number name of the lock that admits a day's new campaign tags
    # one at a time (pg_advisory_xact_lock): this constant, and the day.
    CAMPAIGN_LOCK_NAMESPACE = 0x4D4B_5447
    CAMPAIGN_LOCK_SQL = 'SELECT pg_advisory_xact_lock(?, ?)'

    # A row for a tag that has no row yet. The tag keeps its own name while
    # the day has room for it and joins OVERFLOW_CAMPAIGN after that; the
    # decision and the insert are one statement, run while holding the day's
    # lock, so two new tags arriving together cannot both take the last place.
    ADMIT_CAMPAIGN_SQL = <<~SQL.squish
      INSERT INTO marketing_page_counts (day, event, path, source, campaign, device, count)
      SELECT :day, :event, :path, :source,
             CASE WHEN EXISTS (SELECT 1 FROM marketing_page_counts WHERE day = :day AND campaign = :campaign)
                    OR (SELECT COUNT(DISTINCT campaign) FROM marketing_page_counts
                        WHERE day = :day AND campaign NOT IN ('', :overflow)) < :cap
                  THEN :campaign ELSE :overflow END,
             :device, 1
      ON CONFLICT (day, event, path, source, campaign, device)
      DO UPDATE SET count = marketing_page_counts.count + 1
    SQL

    module_function

    # ---- sorting one request into labels ---------------------------------
    #
    # Everything in this section reads what a stranger sent — an address, a
    # referring address, a user agent, a hidden form field — and none of it
    # may ever fail a page. Each reader therefore answers "nothing" for input
    # it cannot make sense of (the wrong type, bytes that are not text,
    # something far too long), and the entry points below (`origin_for`,
    # `signup_origin`, `public_path`) catch whatever is left: an attribution
    # that cannot be worked out is "no origin", never an error page.

    def bot?(user_agent)
      user_agent.blank? || BOT_PATTERN.match?(user_agent)
    end

    # A browser warming a link up before anybody has clicked it.
    def prefetch?(request)
      PREFETCH_HEADERS.any? { |header| request.get_header(header).to_s.match?(/prefetch|prerender|preview/i) }
    end

    def device(user_agent)
      DetectBrowserDevice.call(user_agent) || 'unknown'
    rescue StandardError
      'unknown'
    end

    # A short piece of real text, lowercased, or nothing at all.
    def label(raw)
      return '' unless raw.is_a?(String) && raw.bytesize <= MAX_TAG_BYTES && raw.valid_encoding?

      raw.strip.downcase
    end

    def normalize_tag(raw)
      tag = label(raw)

      tag if tag.match?(CAMPAIGN_FORMAT)
    end

    # ?ct= wins over ?utm_campaign= when a link carries both.
    def campaign_tag(params)
      normalize_tag(params['ct']) || normalize_tag(params['utm_campaign']) || ''
    end

    def tagged_source(params)
      ct = normalize_tag(params['ct'])
      from_tag = TAG_PREFIXES[ct[/\A([a-z]{2})-/, 1]] if ct

      from_tag || UTM_SOURCES[label(params['utm_source'])] || ('email' if label(params['utm_medium']) == 'email')
    end

    def referrer_source(referrer, host)
      return 'direct' if referrer.blank?

      uri = URI.parse(referrer.to_s.strip)

      return ANDROID_APPS.fetch(uri.host.to_s, 'other') if uri.scheme == 'android-app'
      return 'direct' unless %w[http https].include?(uri.scheme)

      referring_host = uri.host.to_s.downcase.delete_prefix('www.')

      return 'direct' if referring_host.blank?
      return 'internal' if referring_host == host.to_s.downcase.delete_prefix('www.')

      REFERRER_HOSTS.find { |_, pattern| pattern.match?(referring_host) }&.first || 'other'
    rescue StandardError
      'direct'
    end

    # Where one request came from: a tag in its own address says so outright;
    # otherwise the referring address is sorted into a label and forgotten.
    def origin(params:, referrer:, host:)
      Origin.new(tagged_source(params) || referrer_source(referrer, host), campaign_tag(params))
    end

    def no_origin
      Origin.new('direct', '')
    end

    # Reading the request's own query can itself raise (a query Rack refuses
    # to parse, bytes that are not text). That is the visitor's page to be
    # answered however the app answers it — not something the counter may
    # turn into an error by asking first.
    def origin_for(request)
      origin(params: request.query_parameters, referrer: request.referer, host: request.host)
    rescue StandardError
      no_origin
    end

    # The sign-up page is one click away from the page the visitor landed on,
    # and that page's address is where the tag is. So when the sign-up page
    # carries no tag of its own and was opened from one of our pages, the tag
    # is read from that page's address instead.
    def signup_origin(request)
      own = origin_for(request)

      return own if own.campaign.present? || own.source != 'internal'

      carried = internal_referrer_params(request)

      Origin.new(tagged_source(carried) || own.source, campaign_tag(carried))
    rescue StandardError
      no_origin
    end

    # Rack refuses a query with too many parameters by raising, so the size
    # is checked here first and every refusal means "nothing was carried".
    def internal_referrer_params(request)
      query = URI.parse(request.referer.to_s).query.to_s

      return {} if query.bytesize > MAX_QUERY_BYTES

      Rack::Utils.parse_query(query)
    rescue StandardError
      {}
    end

    # The public page an address names, or ELSEWHERE_PATH. Nothing that is
    # not on the list is ever returned, so nothing else can be stored.
    def public_path(path)
      path = path.to_s
      path = path.chomp('/') if path.length > 1

      return path if PUBLIC_PATHS.include?(path) || help_article?(path)

      ELSEWHERE_PATH
    rescue StandardError
      ELSEWHERE_PATH
    end

    def help_article?(path)
      path.start_with?(HELP_ARTICLE_PREFIX) && HelpCenter.article(path.delete_prefix(HELP_ARTICLE_PREFIX)).present?
    end

    # The page a sign-up page was opened from, when it was one of our public
    # ones. An invitation link, a signing link or anything else on this site
    # is "elsewhere": those addresses are private to the person holding them.
    def referring_path(request)
      return ELSEWHERE_PATH unless referrer_source(request.referer, request.host) == 'internal'

      public_path(URI.parse(request.referer.to_s).path)
    rescue StandardError
      ELSEWHERE_PATH
    end

    # What the sign-up form carries from the page to the POST in a hidden
    # field, so a finished sign-up can be counted against its tag without a
    # cookie. It comes back from the browser, so it is read with the same
    # rules as an address: a source off the list or a malformed tag is dropped.
    def signup_token(origin)
      "#{origin.source}:#{origin.campaign}"
    end

    def signup_token_for(request)
      signup_token(signup_origin(request))
    rescue StandardError
      signup_token(no_origin)
    end

    def origin_from_token(token)
      return no_origin unless token.is_a?(String) && token.bytesize <= MAX_TAG_BYTES * 2 && token.valid_encoding?

      source, campaign = token.split(':', 2)

      Origin.new(SOURCES.key?(source) ? source : 'direct', normalize_tag(campaign) || '')
    rescue StandardError
      no_origin
    end

    # The same value, read back and written out again: what the form shows
    # after a refusal is never what was posted.
    def clean_signup_token(token)
      signup_token(origin_from_token(token))
    end

    # ---- counting ---------------------------------------------------------

    # A person (as far as a user agent can tell) loading a page for real.
    def countable?(request)
      request.get? && !prefetch?(request) && !bot?(request.user_agent)
    end

    # What a view of this page would be counted as. Decided in the
    # controller; written by the middleware once the final status is known.
    def view_tally(request)
      { event: VIEW, path: public_path(request.path), origin: origin_for(request),
        device: device(request.user_agent) }
    end

    def signup_open_tally(request)
      { event: SIGNUP_OPEN, path: referring_path(request), origin: signup_origin(request),
        device: device(request.user_agent) }
    end

    def record_signup(token, user_agent)
      increment!(event: SIGNUP, path: SIGNUP_PATH, origin: origin_from_token(token), device: device(user_agent))
    rescue StandardError => e
      ErrorReport.error(e)

      false
    end

    # Add one to a counter, inside a short time budget. A tally that would
    # have to wait — on another transaction's lock, on a slow database — is
    # dropped rather than waited for, and one that fails for any other reason
    # is reported and dropped: no visitor's page may fail, or wait, for this.
    def increment!(event:, path:, origin:, device:, day: MarketingAdmin.today)
      row = { day:, event:, path:, source: origin.source, campaign: origin.campaign.to_s, device: }

      within_time_budget { row[:campaign].empty? ? add_one(row) : add_one_tagged(row) }

      true
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::QueryCanceled, ActiveRecord::Deadlocked
      false
    rescue StandardError => e
      ErrorReport.error(e)

      false
    end

    # Untagged traffic, which is nearly all of it: one upsert.
    def add_one(row)
      MarketingPageCount.upsert(row.merge(count: 1), unique_by: :index_marketing_page_counts_unique,
                                                     on_duplicate: Arel.sql('count = marketing_page_counts.count + 1'))
    end

    # Tagged traffic. A tag that already has this row today is one UPDATE and
    # asks nothing else. Only a row that does not exist yet goes through
    # admission, behind the day's lock (ADMIT_CAMPAIGN_SQL says why).
    def add_one_tagged(row)
      return if MarketingPageCount.where(row).update_all('count = count + 1') == 1

      connection = MarketingPageCount.connection
      connection.execute(
        MarketingPageCount.sanitize_sql_array([CAMPAIGN_LOCK_SQL, CAMPAIGN_LOCK_NAMESPACE, row[:day].jd])
      )
      connection.execute(
        MarketingPageCount.sanitize_sql_array(
          [ADMIT_CAMPAIGN_SQL, row.merge(overflow: OVERFLOW_CAMPAIGN, cap: MAX_CAMPAIGNS_PER_DAY)]
        )
      )
    end

    # The tally's own transaction, with a lock wait and a statement that may
    # each last only a moment (SET LOCAL: the limits end with the transaction
    # and never touch anything else on the connection). When a transaction is
    # already open around it — a test, or a caller that wraps one — the limits
    # would outlive the savepoint, so the previous ones are put back.
    def within_time_budget
      connection = MarketingPageCount.connection
      nested = connection.transaction_open?

      MarketingPageCount.transaction(requires_new: true) do
        before = time_budget(connection) if nested
        limit_time(connection, "#{LOCK_BUDGET_MS}ms", "#{STATEMENT_BUDGET_MS}ms")

        yield

        limit_time(connection, *before) if nested
      end
    end

    def time_budget(connection)
      connection.select_rows("SELECT current_setting('lock_timeout'), current_setting('statement_timeout')").first
    end

    def limit_time(connection, lock, statement)
      connection.execute("SET LOCAL lock_timeout = #{connection.quote(lock)}; " \
                         "SET LOCAL statement_timeout = #{connection.quote(statement)}")
    end

    # ---- reading ----------------------------------------------------------

    RANGES = [1, 7, 30].freeze
    DEFAULT_RANGE = 30
    SERIES_DAYS = 30
    LIST_LIMIT = 8

    def report(range: DEFAULT_RANGE, today: MarketingAdmin.today)
      range = DEFAULT_RANGE unless RANGES.include?(range)
      window = MarketingPageCount.where(day: (today - (range - 1))..today)

      { range:, **history(today), **breakdowns(window.where(event: VIEW)),
        **signup_interest(window), campaigns: campaign_rows(window) }
    end

    # The headline numbers and the thirty-day chart. They do not follow the
    # chosen period: they are the same whichever breakdown is being read.
    def history(today)
      first_day = MarketingPageCount.minimum(:day)
      days = ((today - (SERIES_DAYS - 1))..today).to_a
      by_day = MarketingPageCount.where(day: days.first..today).group(:day, :event).sum(:count)
      views_on = ->(day) { by_day.fetch([day, VIEW], 0) }

      { first_day:, today: views_on.call(today), last7: days.last(7).sum(&views_on),
        previous7: days.last(14).first(7).sum(&views_on), last30: days.sum(&views_on),
        daily: days.map do |day|
          { day:, counted: first_day.present? && day >= first_day, views: views_on.call(day),
            signup_opens: by_day.fetch([day, SIGNUP_OPEN], 0) }
        end }
    end

    def breakdowns(views)
      { view_total: views.sum(:count),
        pages: ranked(views.group(:path).sum(:count)) { |path| page_label(path) },
        sources: ranked(views.group(:source).sum(:count)) { |source| SOURCES.fetch(source, source) },
        devices: ranked(views.group(:device).sum(:count)) { |device| DEVICES.fetch(device, device) } }
    end

    def signup_interest(window)
      views = window.where(event: VIEW).sum(:count)
      opens = window.where(event: SIGNUP_OPEN)
      total = opens.sum(:count)

      { signup_opens: total,
        signup_opens_by_page: ranked(opens.group(:path).sum(:count)) { |path| origin_page_label(path) },
        signup_rate: views.positive? ? (total * 100.0 / views).round(1) : nil }
    end

    # Per tag: page views, sign-up pages opened and sign-ups that went
    # through, so a tag can be followed from the click to the account.
    def campaign_rows(window)
      counts = window.where.not(campaign: '').group(:campaign, :event).sum(:count)

      rows = counts.keys.map(&:first).uniq.map do |campaign|
        { key: campaign, label: campaign == OVERFLOW_CAMPAIGN ? 'All other tags' : campaign,
          source: campaign_source(campaign),
          views: counts.fetch([campaign, VIEW], 0),
          signup_opens: counts.fetch([campaign, SIGNUP_OPEN], 0),
          signups: counts.fetch([campaign, SIGNUP], 0) }
      end

      rows.sort_by { |row| [-row[:views], -row[:signups], row[:key]] }.first(LIST_LIMIT * 2)
    end

    def page_label(path)
      { '/' => 'Home page', ELSEWHERE_PATH => 'Other pages' }.fetch(path, path)
    end

    def origin_page_label(path)
      path == ELSEWHERE_PATH ? 'Somewhere else, or opened directly' : page_label(path)
    end

    def campaign_source(campaign)
      SOURCES[TAG_PREFIXES[campaign[/\A([a-z]{2})-/, 1]]]
    end

    # The block turns a stored value into the words the page shows for it.
    def ranked(counts)
      total = counts.values.sum

      counts.sort_by { |key, value| [-value, key.to_s] }.first(LIST_LIMIT).map do |key, value|
        { key:, label: yield(key), value:, share: total.positive? ? value.to_f / total : 0 }
      end
    end
  end
end
