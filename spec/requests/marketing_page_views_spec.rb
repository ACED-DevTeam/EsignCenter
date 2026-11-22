# frozen_string_literal: true

# The website counter behind /admin (MarketingAdmin::Traffic,
# MarketingPageViews). It counts page views on the public pages as plain
# totals — per day, page, source, campaign tag and device type — and it must
# count people only: not bots, not signed-in customers, not prefetches, not
# error pages. It must also never keep anything that could single a visitor out.
RSpec.describe 'Marketing page view counter', type: :request do
  stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'TURNSTILE_SECRET_KEY', 'MARKETING_ADMIN_EMAILS',
            clear: true

  let(:browser) do
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) ' \
      'Chrome/130.0.0.0 Safari/537.36'
  end
  let(:phone) do
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) ' \
      'Version/18.0 Mobile/15E148 Safari/604.1'
  end
  let(:today) { MarketingAdmin.today }

  # The instance is set up, so no public page is the first-run redirect.
  before { create(:user, account: create(:account, :operator)) }

  def visit(path, agent: browser, referer: nil, headers: {})
    get path, headers: { 'User-Agent' => agent, 'Referer' => referer }.compact.merge(headers)
  end

  def counts
    MarketingPageCount.all.map { |row| row.attributes.except('id', 'day').symbolize_keys }
  end

  describe 'what is counted' do
    {
      '/' => '/', '/pricing' => '/pricing', '/trust' => '/trust', '/trust/subprocessors' => '/trust/subprocessors',
      '/terms' => '/terms', '/privacy' => '/privacy', '/help' => '/help', '/support' => '/support',
      '/docs/api' => '/docs/api', '/pricing/' => '/pricing'
    }.each do |path, counted_as|
      it "counts a visit to #{path}" do
        visit(path)

        expect(response).to have_http_status(:ok)
        expect(counts).to eq([{ event: 'view', path: counted_as, source: 'direct', campaign: '', device: 'desktop',
                                count: 1 }])
        expect(MarketingPageCount.first.day).to eq(today)
      end
    end

    it 'counts a help article under its own address' do
      slug = HelpCenter.sections.values.flatten.first.slug

      visit("/help/#{slug}")

      expect(counts.pluck(:path)).to eq(["/help/#{slug}"])
    end

    it 'adds to the same counter instead of writing a row per visit' do
      3.times { visit('/pricing') }
      visit('/pricing', agent: phone)

      expect(counts).to contain_exactly(
        { event: 'view', path: '/pricing', source: 'direct', campaign: '', device: 'desktop', count: 3 },
        { event: 'view', path: '/pricing', source: 'direct', campaign: '', device: 'mobile', count: 1 }
      )
    end

    it 'counts by America/Chicago day, whatever day it is in UTC' do
      travel_to(Time.utc(2026, 11, 22, 3, 30)) { visit('/pricing') }

      expect(MarketingPageCount.pluck(:day)).to eq([Date.new(2026, 11, 21)])
    end
  end

  describe 'what is not counted' do
    it 'skips bots, link previews, scripts and requests with no user agent' do
      ['Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
       'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)',
       'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
       'Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)',
       'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/130.0.0.0 Safari/537.36',
       'curl/8.5.0', 'python-requests/2.32.3', 'UptimeRobot/2.0', ''].each do |agent|
        visit('/pricing', agent:)

        expect(response).to have_http_status(:ok)
      end

      expect(MarketingPageCount.count).to eq(0)
    end

    it 'skips signed-in users on the same public pages' do
      sign_in(create(:user))

      visit('/pricing')
      visit('/help')

      expect(response).to have_http_status(:ok)
      expect(MarketingPageCount.count).to eq(0)
    end

    it 'skips a browser prefetching a link nobody has clicked yet' do
      visit('/pricing', headers: { 'Sec-Purpose' => 'prefetch;prerender' })
      visit('/pricing', headers: { 'Purpose' => 'prefetch' })
      visit('/pricing', headers: { 'X-Sec-Purpose' => 'prefetch' })
      visit('/pricing', headers: { 'X-Moz' => 'prefetch' })

      expect(MarketingPageCount.count).to eq(0)
    end

    it 'skips pages that were not found, requests that are not page loads and the app itself' do
      expect { visit('/help/no-such-article') }.to raise_error(ActionController::RoutingError)

      head '/pricing', headers: { 'User-Agent' => browser }
      visit('/docs/openapi.json')
      visit('/sign_in')
      visit('/verify')
      post '/support', params: {}, headers: { 'User-Agent' => browser }

      expect(MarketingPageCount.count).to eq(0)
    end

    it 'does not count the marketing page itself, or anything behind sign-in' do
      ENV['MARKETING_ADMIN_EMAILS'] = 'marketer@example.com'
      listed = signed_up_themselves(create(:user, email: 'marketer@example.com'))
      sign_in_with_password(listed)

      visit('/admin')
      visit(settings_profile_index_path)

      expect(response).to have_http_status(:ok)
      expect(MarketingPageCount.count).to eq(0)
    end

    # A browser that already holds the page asks with If-None-Match, and the
    # conditional-GET middleware answers 304 and sends nothing — after the
    # controller has finished with a 200. Nobody was shown a page.
    it 'does not count a conditional request that is answered 304 Not Modified' do
      visit('/pricing')
      etag = response.headers['ETag']

      expect(etag).to be_present

      visit('/pricing', headers: { 'If-None-Match' => etag })

      expect(response).to have_http_status(:not_modified)
      expect(response.body).to be_empty
      expect(MarketingPageCount.sum(:count)).to eq(1)

      # A conditional request the page has changed under is a real view.
      visit('/pricing', headers: { 'If-None-Match' => 'W/"something-older"' })

      expect(response).to have_http_status(:ok)
      expect(MarketingPageCount.sum(:count)).to eq(2)
    end

    it 'never fails or changes a page because the counter could not be written' do
      allow(MarketingPageCount).to receive(:upsert).and_raise(ActiveRecord::StatementInvalid, 'no table')
      allow(ErrorReport).to receive(:error)

      visit('/pricing')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Pricing')
      expect(ErrorReport).to have_received(:error)
    end
  end

  describe 'where a visit came from' do
    {
      'https://www.google.com/' => 'google',
      'https://www.google.co.uk/search?q=esign' => 'google',
      'https://mail.google.com/mail/u/0/' => 'email',
      'https://l.facebook.com/l.php?u=x' => 'facebook',
      'https://www.instagram.com/' => 'instagram',
      'https://www.youtube.com/watch?v=abc' => 'youtube',
      'https://youtu.be/abc' => 'youtube',
      'https://www.tiktok.com/@esigncenter' => 'tiktok',
      'https://old.reddit.com/r/freelance/comments/1' => 'reddit',
      'https://chatgpt.com/' => 'chatgpt',
      'https://www.linkedin.com/feed/' => 'linkedin',
      'android-app://com.google.android.gm/' => 'email',
      'https://news.example.org/story' => 'other',
      'http://www.example.com/pricing' => 'internal',
      'not a url at all' => 'direct'
    }.each do |referer, source|
      it "files #{referer} under #{source}" do
        visit('/pricing', referer:)

        expect(counts.pluck(:source, :campaign)).to eq([[source, '']])
      end
    end

    it 'reads Chore Lock-style ct tags and utm tags from the address' do
      visit('/?ct=yt-how-to-sign')
      visit('/pricing?ct=RD-Freelance_Thread', referer: 'https://www.google.com/')
      visit('/trust?utm_source=newsletter&utm_campaign=november')
      visit('/help?utm_source=chatgpt.com')
      visit('/terms?utm_medium=email')
      visit('/privacy?ct=launch-week', referer: 'https://www.linkedin.com/')

      expect(counts.pluck(:path, :source, :campaign)).to contain_exactly(
        ['/', 'youtube', 'yt-how-to-sign'],
        ['/pricing', 'reddit', 'rd-freelance_thread'],
        ['/trust', 'email', 'november'],
        ['/help', 'chatgpt', ''],
        ['/terms', 'email', ''],
        ['/privacy', 'linkedin', 'launch-week']
      )
    end

    it 'drops a tag that does not look like one of ours rather than storing what a stranger typed' do
      visit('/pricing?ct=%3Cscript%3Ealert(1)%3C/script%3E')
      visit("/pricing?ct=#{'a' * 49}")
      visit('/pricing?ct=someone@example.com')
      visit('/pricing?ct[]=yt-x')
      visit('/pricing?utm_campaign=has%20spaces')

      expect(counts).to eq([{ event: 'view', path: '/pricing', source: 'direct', campaign: '', device: 'desktop',
                              count: 5 }])
    end

    it 'stops keeping new tags once a day has a hundred of them' do
      stub_const('MarketingAdmin::Traffic::MAX_CAMPAIGNS_PER_DAY', 3)

      %w[yt-a yt-b yt-c yt-d yt-e yt-a].each { |tag| visit("/pricing?ct=#{tag}") }

      expect(counts.pluck(:campaign, :count)).to contain_exactly(['yt-a', 2], ['yt-b', 1], ['yt-c', 1], ['~more', 2])
    end
  end

  # The page a view is filed under is the one thing in a row that comes from
  # an address, and an address can carry a secret. Nothing is stored as it
  # arrived: it has to be one of the public pages, or it is "elsewhere".
  describe 'which pages can ever be stored' do
    it 'files a sign-up page opened from an invitation link under "elsewhere", never under the link' do
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
      ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'

      visit('/sign_up', referer: 'http://www.example.com/invites/SECRET-invitation-token-123')
      visit('/sign_up', referer: 'http://www.example.com/s/a-signing-link-slug')
      visit('/sign_up', referer: 'http://www.example.com/invitation?reset_password_token=SECRET-reset')

      expect(response).to have_http_status(:ok)
      expect(counts).to eq([{ event: 'signup_open', path: '(elsewhere)', source: 'internal', campaign: '',
                              device: 'desktop', count: 3 }])
      expect(MarketingPageCount.pluck(:path, :source, :campaign).flatten.join(' '))
        .not_to match(/SECRET|invites|signing-link|reset/)
    end

    it 'cannot be made to grow by sending made-up addresses' do
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
      ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'

      25.times { |i| visit('/sign_up', referer: "http://www.example.com/made-up-#{i}/#{SecureRandom.hex(40)}") }

      expect(MarketingPageCount.count).to eq(1)
      expect(MarketingPageCount.first).to have_attributes(path: '(elsewhere)', count: 25)
    end

    it 'knows the public pages and the help centre’s own articles, and nothing else' do
      traffic = MarketingAdmin::Traffic
      article = "/help/#{HelpCenter.articles.first.slug}"

      expect(traffic::PUBLIC_PATHS.map { |path| traffic.public_path(path) }).to eq(traffic::PUBLIC_PATHS)
      expect(traffic.public_path(article)).to eq(article)
      expect(traffic.public_path('/pricing/')).to eq('/pricing')

      ['/help/no-such-article', '/invites/abc', '/s/abc', '/PRICING', '/pricing/extra', '/admin', '/sign_up',
       "/#{'a' * 5000}", "/caf\xE9".b, nil, 42].each do |path|
        expect(traffic.public_path(path)).to eq('(elsewhere)'), path.inspect
      end
    end

    it 'counts every page that is counted under a page on the list' do
      (MarketingAdmin::Traffic::PUBLIC_PATHS + ["/help/#{HelpCenter.articles.first.slug}"]).each { |path| visit(path) }

      expect(MarketingPageCount.where(path: '(elsewhere)')).to be_empty
      expect(MarketingPageCount.pluck(:path)).to match_array(
        MarketingAdmin::Traffic::PUBLIC_PATHS + ["/help/#{HelpCenter.articles.first.slug}"]
      )
    end
  end

  # Working out where a visit came from reads what a stranger sent. Whatever
  # that is, the page they asked for is answered as it always was.
  describe 'input the counter cannot make sense of' do
    before do
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
      ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
    end

    {
      'a referring address with more parameters than Rack will parse' =>
        "http://www.example.com/pricing?#{(1..6000).map { |i| "p#{i}=1" }.join('&')}",
      'a referring address nested deeper than Rack will parse' =>
        "http://www.example.com/pricing?ct#{'[x]' * 150}=1",
      'a referring address whose tag is not text' => 'http://www.example.com/pricing?ct=%FF%FE%FD',
      'a referring address that is megabytes long' => "http://www.example.com/pricing?ct=#{'a' * 300_000}",
      'a referring address that is not an address' => "http://www.example.com:99999999/\u0000 ::%%",
      'a referring address in bytes that are not text' => "http://www.example.com/pricing?ct=\xFF\xFE".b
    }.each do |what, referer|
      it "still shows the sign-up form, and a public page, for #{what}" do
        visit('/sign_up', referer:)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('user[email]')
        expect(Nokogiri::HTML(response.body).at_css('input[name="signup_origin"]')['value'])
          .to match(/\A(internal|direct):\z/)

        visit('/pricing', referer:)

        expect(response).to have_http_status(:ok)
        expect(MarketingPageCount.distinct.pluck(:campaign)).to eq([''])
      end
    end

    it 'still counts the visit when the tag is thrown away' do
      visit('/pricing', referer: 'http://www.example.com/?ct=%FF')

      expect(counts).to eq([{ event: 'view', path: '/pricing', source: 'internal', campaign: '', device: 'desktop',
                              count: 1 }])
    end

    # The app itself refuses a query it cannot parse, with or without the
    # counter. The counter must neither cause that nor count it.
    it 'leaves a request the app itself refuses exactly as it was, and counts nothing' do
      ['/pricing?ct=%FF%FE', '/pricing?ct=a&ct[b]=c', "/pricing?a#{'[x]' * 200}=1"].each do |path|
        expect { visit(path) }.to raise_error(ActionController::BadRequest)
      end

      allow_any_instance_of(MarketingController).to receive(:count_marketing_page_view)

      expect { visit('/pricing?ct=%FF%FE') }.to raise_error(ActionController::BadRequest)
      expect(MarketingPageCount.count).to eq(0)
    end

    it 'signs somebody up whatever shape the hidden field comes back in' do
      stub_turnstile

      [%w[an array], { 'a' => 'hash' }, 'x' * 5000, 'youtube:<script>', ''].each_with_index do |origin, index|
        post registration_path,
             params: { user: { name: 'Ada Lovelace', email: "ada#{index}@example.com", password: 'a-long-password',
                               timezone: 'Europe/Paris' },
                       'cf-turnstile-response' => 'turnstile-token', signup_origin: origin,
                       **LegalDocuments.version_fields },
             headers: { 'User-Agent' => browser }

        expect(response).to redirect_to(confirm_registration_path), origin.inspect
        RateLimit.store.clear
      end

      expect(User.where('email LIKE ?', 'ada%@example.com').count).to eq(5)
      expect(counts.pluck(:event, :source, :campaign, :count)).to contain_exactly(['signup', 'direct', '', 4],
                                                                                  ['signup', 'youtube', '', 1])
    end
  end

  # A tally is one small write, and it gets a moment to make it. If the
  # database makes it wait — another transaction holding the row — the tally
  # is dropped. Real connections and real locks, so no transactional fixture.
  describe 'when the database makes the counter wait' do
    self.use_transactional_tests = false

    let(:day) { MarketingAdmin.today }
    let(:row) { { day:, event: 'view', path: '/pricing', source: 'direct', campaign: '', device: 'desktop' } }

    # These examples commit for real, so they tidy up for real: everything
    # they made hangs off an account or is a counter row.
    after do
      ActiveRecord::Base.connection.execute('TRUNCATE accounts, users, marketing_page_counts CASCADE')
    end

    # Holds the row's lock from another connection until the block returns.
    def while_locked
      locked = Queue.new
      release = Queue.new
      holder = Thread.new do
        MarketingPageCount.connection_pool.with_connection do
          MarketingPageCount.transaction do
            MarketingPageCount.where(row).lock.load
            locked << true
            release.pop
          end
        end
      end
      locked.pop

      yield
    ensure
      release << true
      holder.join
    end

    def elapsed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    it 'drops the tally instead of waiting for a locked row, and reports nothing' do
      MarketingPageCount.insert!(row.merge(count: 7))
      allow(ErrorReport).to receive(:error)

      while_locked do
        waited = elapsed do
          expect(MarketingAdmin::Traffic.increment!(event: 'view', path: '/pricing', device: 'desktop',
                                                    origin: MarketingAdmin::Traffic.no_origin)).to be(false)
        end

        expect(waited).to be < 1
      end

      expect(MarketingPageCount.find_by!(row).count).to eq(7)
      expect(ErrorReport).not_to have_received(:error)
      # The time limits ended with the tally's own transaction.
      expect(MarketingPageCount.connection.select_value('SHOW lock_timeout')).to eq('0')
      expect(MarketingPageCount.connection.select_value('SHOW statement_timeout')).to eq('0')
    end

    it 'answers the public page and the sign-up at once while the counter is stuck' do
      create(:user, account: create(:account, :operator))
      MarketingPageCount.insert!(row.merge(count: 7))
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
      ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
      stub_turnstile

      while_locked do
        waited = elapsed { visit('/pricing') }

        expect(response).to have_http_status(:ok)
        expect(waited).to be < 2
      end

      MarketingPageCount.insert!(row.merge(event: 'signup', path: '/sign_up', count: 1))

      row[:event] = 'signup'
      row[:path] = '/sign_up'

      while_locked do
        post registration_path,
             params: { user: { name: 'Ada Lovelace', email: 'ada@example.com', password: 'a-long-password',
                               timezone: 'Europe/Paris' },
                       'cf-turnstile-response' => 'turnstile-token', signup_origin: 'direct:',
                       **LegalDocuments.version_fields },
             headers: { 'User-Agent' => browser }

        expect(response).to redirect_to(confirm_registration_path)
      end

      expect(User.find_by(email: 'ada@example.com')).to be_present
      expect(MarketingPageCount.find_by!(row).count).to eq(1)
    end

    # Two new tags arriving at the same moment must not both take the last
    # place: admission is one statement behind the day's lock.
    it 'admits exactly as many new tags as the day has room for, however they arrive' do
      stub_const('MarketingAdmin::Traffic::MAX_CAMPAIGNS_PER_DAY', 3)
      stub_const('MarketingAdmin::Traffic::LOCK_BUDGET_MS', 5000)
      stub_const('MarketingAdmin::Traffic::STATEMENT_BUDGET_MS', 5000)

      start = Queue.new
      threads = Array.new(8) do |index|
        Thread.new do
          start.pop
          MarketingPageCount.connection_pool.with_connection do
            MarketingAdmin::Traffic.increment!(
              event: 'view', path: '/pricing', device: 'desktop',
              origin: MarketingAdmin::Traffic::Origin.new('youtube', "yt-tag-#{index}")
            )
          end
        end
      end
      8.times { start << true }

      expect(threads.map(&:value)).to all(be(true))

      kept = MarketingPageCount.where.not(campaign: ['', '~more']).distinct.pluck(:campaign)

      expect(kept.size).to eq(3)
      expect(MarketingPageCount.sum(:count)).to eq(8)
      expect(MarketingPageCount.find_by!(campaign: '~more').count).to eq(5)
    end
  end

  describe 'what one tally asks of the database' do
    def statements
      seen = []
      subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        seen << payload[:sql] unless payload[:name] == 'SCHEMA'
      end

      yield

      seen
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'writes an untagged view with one statement and reads nothing' do
      sql = statements { visit('/pricing') }.grep(/marketing_page_counts/)

      expect(sql.size).to eq(1)
      expect(sql.first).to start_with('INSERT INTO "marketing_page_counts"')
    end

    it 'adds to a tag that already has its row with one UPDATE, without asking about the cap' do
      visit('/pricing?ct=yt-how-to-sign')

      sql = statements { visit('/pricing?ct=yt-how-to-sign') }

      expect(sql.grep(/marketing_page_counts/))
        .to contain_exactly(a_string_starting_with('UPDATE "marketing_page_counts"'))
      expect(sql.grep(/pg_advisory|COUNT\(DISTINCT/)).to be_empty
      expect(MarketingPageCount.find_by!(campaign: 'yt-how-to-sign').count).to eq(2)
    end

    it 'puts the time limits back when it runs inside somebody else’s transaction' do
      MarketingPageCount.connection.execute("SET LOCAL lock_timeout = '4s'")

      visit('/pricing?ct=yt-how-to-sign')

      expect(MarketingPageCount.connection.select_value('SHOW lock_timeout')).to eq('4s')
      expect(MarketingPageCount.connection.select_value('SHOW statement_timeout')).to eq('0')
    end
  end

  describe 'what the table can hold' do
    # The privacy promise is structural: there is nowhere to put a visitor.
    it 'has no column for an address, a user agent, a referrer, an id or a time' do
      expect(MarketingPageCount.column_names).to contain_exactly('id', 'day', 'event', 'path', 'source', 'campaign',
                                                                 'device', 'count')
    end

    it 'keeps a label for the referrer and nothing of the address itself' do
      visit('/pricing?ref=secret-token', referer: 'https://www.reddit.com/r/private/comments/abc/my_real_name')

      stored = MarketingPageCount.first.attributes.values.join(' ')

      expect(stored).not_to include('private', 'my_real_name', 'secret-token')
      expect(stored).to include('reddit', '/pricing')
    end
  end

  describe 'the sign-up page' do
    before do
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
      ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
      RateLimit.store.clear
    end

    def origin_field
      Nokogiri::HTML(response.body).at_css('input[name="signup_origin"]')['value']
    end

    def signup_params(origin:, email: 'ada@example.com')
      { user: { name: 'Ada Lovelace', email:, password: 'a-long-password', timezone: 'Europe/Paris' },
        'cf-turnstile-response' => 'turnstile-token', signup_origin: origin, **LegalDocuments.version_fields }
    end

    it 'counts an opened sign-up page against the page the click came from, carrying that page’s tag' do
      visit('/sign_up', referer: 'http://www.example.com/pricing?ct=yt-how-to-sign')

      expect(counts).to eq([{ event: 'signup_open', path: '/pricing', source: 'youtube', campaign: 'yt-how-to-sign',
                              device: 'desktop', count: 1 }])
      expect(origin_field).to eq('youtube:yt-how-to-sign')
    end

    it 'counts a sign-up page opened from elsewhere without inventing an origin page' do
      visit('/sign_up?ct=rd-thread', referer: 'https://www.reddit.com/r/freelance')
      visit('/sign_up')

      expect(counts.pluck(:path, :source, :campaign)).to contain_exactly(['(elsewhere)', 'reddit', 'rd-thread'],
                                                                         ['(elsewhere)', 'direct', ''])
    end

    it 'does not count a bot opening the sign-up page' do
      visit('/sign_up', agent: 'Mozilla/5.0 (compatible; bingbot/2.0)')

      expect(MarketingPageCount.count).to eq(0)
    end

    it 'counts a finished sign-up against its tag, and stores nothing about it on the account' do
      stub_turnstile

      post registration_path, params: signup_params(origin: 'youtube:yt-how-to-sign'),
                              headers: { 'User-Agent' => phone }

      expect(response).to redirect_to(confirm_registration_path)
      expect(counts).to eq([{ event: 'signup', path: '/sign_up', source: 'youtube', campaign: 'yt-how-to-sign',
                              device: 'mobile', count: 1 }])

      account = User.find_by!(email: 'ada@example.com').account

      expect(account.attributes.values.join(' ')).not_to include('yt-how-to-sign')
      expect(account.users.first.attributes.values.join(' ')).not_to include('yt-how-to-sign')
    end

    it 'does not count a sign-up that was refused, and carries a clean value back into the form' do
      stub_turnstile(success: false)

      post registration_path, params: signup_params(origin: 'made-up-source:<b>nope</b>'),
                              headers: { 'User-Agent' => browser }

      expect(response).to have_http_status(:unprocessable_content)
      expect(MarketingPageCount.count).to eq(0)
      expect(origin_field).to eq('direct:')
    end

    it 'still signs somebody up when the hidden field is missing or the counter is broken' do
      stub_turnstile
      allow(MarketingPageCount).to receive(:upsert).and_raise(ActiveRecord::StatementInvalid, 'no table')
      allow(ErrorReport).to receive(:error)

      post registration_path, params: signup_params(origin: nil).except(:signup_origin),
                              headers: { 'User-Agent' => browser }

      expect(response).to redirect_to(confirm_registration_path)
      expect(User.find_by(email: 'ada@example.com')).to be_present
    end
  end
end
