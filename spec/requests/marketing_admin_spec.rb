# frozen_string_literal: true

# The private marketing page at /admin (docs/marketing-admin.md). It opens
# for a signed-in, confirmed user whose email is on the list and who made that
# login themselves, and for nobody else — and "nobody else" is answered with a
# 404, the same answer as a page that does not exist, so the page is never
# revealed.
RSpec.describe 'Marketing admin page', type: :request do
  stash_env 'MARKETING_ADMIN_EMAILS', 'MARKETING_YOUTUBE_CHANNEL_ID', 'MARKETING_YOUTUBE_API_KEY',
            'MARKETING_META_PAGE_TOKEN', 'MARKETING_FACEBOOK_PAGE_ID', 'MARKETING_INSTAGRAM_USER_ID',
            'MARKETING_OUTREACH_TOKEN', clear: true

  let(:listed_email) { 'marketer@example.com' }
  let(:luis) { signed_up_themselves(create(:user, email: listed_email)) }
  let(:stranger) { create(:user, email: 'someone.else@example.com') }
  let(:today) { MarketingAdmin.today }
  let(:page) { Nokogiri::HTML(response.body) }

  before { ENV['MARKETING_ADMIN_EMAILS'] = listed_email }

  def connect_youtube!
    ENV['MARKETING_YOUTUBE_CHANNEL_ID'] = 'UCchannel'
    ENV['MARKETING_YOUTUBE_API_KEY'] = 'youtube-api-key-value'
  end

  def connect_meta!
    ENV['MARKETING_META_PAGE_TOKEN'] = 'meta-page-token-value'
    ENV['MARKETING_FACEBOOK_PAGE_ID'] = '1000'
    ENV['MARKETING_INSTAGRAM_USER_ID'] = '2000'
  end

  def snapshot!(platform, day:, followers:, **attributes)
    MarketingSocialSnapshot.create!({ platform:, day:, followers:, collected_by: 'api', fetched_at: Time.current,
                                      posts: [] }.merge(attributes))
  end

  def channel(platform)
    page.at_css("[data-channel='#{platform}']")
  end

  describe 'who can open it' do
    doors = [
      [:get, '/admin'],
      [:post, '/admin/refresh'],
      [:post, '/admin/tiktok']
    ]

    doors.each do |verb, path|
      it "answers #{verb.to_s.upcase} #{path} with a 404 for a signed-out visitor, not a redirect to sign-in" do
        expect { public_send(verb, path) }.to raise_error(ActionController::RoutingError)
      end

      it "answers #{verb.to_s.upcase} #{path} with a 404 for a signed-in user who is not on the list" do
        sign_in_with_password(signed_up_themselves(stranger))

        expect { public_send(verb, path) }.to raise_error(ActionController::RoutingError)
      end
    end

    it 'opens for a listed address that made its own login and signed in with its password' do
      sign_in_with_password(luis)

      get '/admin'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Marketing')
    end

    it 'does not open for a platform operator, an internal admin or an account admin who is not listed' do
      operator = create(:user, account: create(:account, :operator), platform_operator: true)
      operator.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)

      [operator, create(:user, account: create(:account, :internal)), create(:user, :admin)].each do |user|
        sign_in(user)

        expect { get '/admin' }.to raise_error(ActionController::RoutingError)

        sign_out(user)
      end
    end

    # Devise never signs in an unconfirmed user, so there is no session to try
    # this with; the list itself is asked directly, because it must not lean
    # on that rule staying the way it is.
    it 'does not count the listed address as allowed until it has been confirmed' do
      expect(MarketingAdmin.allowed?(luis, warden: session_proving(luis))).to be(true)

      luis.update!(confirmed_at: nil)

      expect(MarketingAdmin.allowed?(luis, warden: session_proving(luis))).to be(false)
      expect(MarketingAdmin.allowed?(nil, warden: session_proving(luis))).to be(false)
    end

    # A session Devise no longer honours would normally be bounced to the
    # sign-in page. Here that bounce would give the page away, so it is a 404.
    it 'does not open for a listed user who was archived after signing in, and does not redirect' do
      sign_in_with_password(luis)
      get '/admin'

      expect(response).to have_http_status(:ok)

      luis.update!(archived_at: Time.current)

      expect { get '/admin' }.to raise_error(ActionController::RoutingError)
      expect(MarketingAdmin.allowed?(luis, warden: session_proving(luis))).to be(false)
    end

    it 'takes the list from MARKETING_ADMIN_EMAILS, comma-separated and in any letter case' do
      ENV['MARKETING_ADMIN_EMAILS'] = ' Dana@Example.com , SAM@example.com'
      dana = signed_up_themselves(create(:user, email: 'dana@example.com'))

      sign_in_with_password(dana)
      get '/admin'

      expect(response).to have_http_status(:ok)

      sign_out_for_real
      sign_in_with_password(luis)

      # Only the addresses in the variable are on the list.
      expect { get '/admin' }.to raise_error(ActionController::RoutingError)
    end

    it 'opens for nobody when the variable is blank or unset' do
      ENV['MARKETING_ADMIN_EMAILS'] = ' , '
      sign_in_with_password(luis)

      expect { get '/admin' }.to raise_error(ActionController::RoutingError)

      ENV.delete('MARKETING_ADMIN_EMAILS')

      expect { get '/admin' }.to raise_error(ActionController::RoutingError)
    end

    it 'does not open for somebody whose address only waits to become a listed one' do
      signed_up_themselves(stranger)
      stranger.update_columns(unconfirmed_email: listed_email)
      sign_in_with_password(stranger)

      expect { get '/admin' }.to raise_error(ActionController::RoutingError)
    end

    # In production an exception is rendered, not raised. What a stranger is
    # sent must be exactly what an address nothing routes sends them, whatever
    # they asked for — a different body, or an empty one, would say "there is
    # something here".
    context 'when errors are rendered as they are in production' do
      around do |example|
        env_config = Rails.application.env_config
        overrides = { 'action_dispatch.show_exceptions' => :all, 'action_dispatch.show_detailed_exceptions' => false }
        saved = overrides.keys.index_with { |key| [env_config.key?(key), env_config[key]] }
        env_config.merge!(overrides)

        example.run
      ensure
        saved.each { |key, (present, value)| present ? env_config[key] = value : env_config.delete(key) }
      end

      [nil, 'text/html', 'application/json', '*/*'].each do |accept|
        it "is byte for byte a missing page when the request accepts #{accept || 'anything'}" do
          headers = accept ? { 'Accept' => accept } : {}

          get '/admin', headers: headers
          hidden = [response.status, response.media_type, response.body]

          get '/there-is-no-such-page', headers: headers

          expect(hidden).to eq([response.status, response.media_type, response.body])
          expect(hidden.first).to eq(404)
          expect(response.headers['Location']).to be_nil
        end
      end

      it 'is a missing page for a signed-in user who is not on the list too' do
        sign_in(stranger)

        get '/admin'

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include('Marketing')
      end
    end

    # Being on the list and confirmed is not proof of owning the mailbox: a
    # login can be made FOR an address by somebody else. The page asks for a
    # login its owner made at a sign-up door, and these are the ways one can
    # exist without that (review, fix round 1).
    describe 'a login somebody else made for a listed address' do
      # The real door: an internal account's administrator adds a user, with a
      # password of their choosing and no confirmation step.
      it 'does not open for a user an internal administrator provisioned with a password' do
        internal_admin = create(:user, account: create(:account, :internal))

        sign_in(internal_admin)
        post users_path, params: { user: { email: listed_email, first_name: 'Not', last_name: 'The Owner',
                                           password: 'chosen-by-the-admin', role: 'admin' } }
        sign_out_for_real

        provisioned = User.find_by!(email: listed_email)

        expect(provisioned).to be_confirmed
        expect(provisioned.valid_password?('chosen-by-the-admin')).to be(true)
        expect(MarketingAdmin.allowed?(provisioned, warden: session_proving(provisioned))).to be(false)

        # Signed in through the real form with the password the admin chose.
        post user_session_path, params: { user: { email: listed_email, password: 'chosen-by-the-admin' } }

        expect(controller.current_user).to eq(provisioned)
        expect { get '/admin' }.to raise_error(ActionController::RoutingError)
        expect { post '/admin/tiktok', params: { followers: '5' } }.to raise_error(ActionController::RoutingError)

        get settings_profile_index_path

        expect(response.body).not_to include('marketing_admin_button')
      end

      it 'does not open for a login made by the setup page, a console or the provisioning API' do
        headless = create(:user, email: listed_email)

        expect(headless).to be_confirmed
        expect(MarketingAdmin.allowed?(headless, warden: session_proving(headless))).to be(false)

        sign_in_with_password(headless)

        expect { get '/admin' }.to raise_error(ActionController::RoutingError)
      end

      it 'does not open for somebody who joined by invitation, which is not one of the sign-up doors' do
        invited = signed_up_themselves(create(:user, email: listed_email), source: LegalAcceptance::INVITE)

        sign_in_with_password(invited)

        expect { get '/admin' }.to raise_error(ActionController::RoutingError)
      end

      it 'counts a login made at the Google or Apple door as its owner’s own, once the session is proven' do
        [LegalAcceptance::SIGNUP_GOOGLE, LegalAcceptance::SIGNUP_APPLE].each_with_index do |source, index|
          email = "owner#{index}@example.com"
          ENV['MARKETING_ADMIN_EMAILS'] = email
          owner = signed_up_themselves(create(:user, email:), source:)

          sign_in_with_password(owner)
          get '/admin'

          expect(response).to have_http_status(:ok)

          sign_out_for_real
        end
      end

      it 'costs users who are not on the list no query at all' do
        sign_in(stranger)
        allow(LegalAcceptance).to receive(:exists?).and_call_original

        get settings_profile_index_path

        expect(response).to have_http_status(:ok)
        expect(LegalAcceptance).not_to have_received(:exists?)
      end
    end

    # With forgery protection on, as it is in production, a stranger's POST
    # must still meet the 404 first: a 422 "invalid authenticity token" would
    # say there is a form behind this address.
    it 'answers a stranger’s POST with the 404 before the forgery check can answer it' do
      ActionController::Base.allow_forgery_protection = true

      ['/admin/refresh', '/admin/tiktok'].each do |path|
        expect { post path }.to raise_error(ActionController::RoutingError)

        sign_in(stranger)
        expect { post path }.to raise_error(ActionController::RoutingError)
        sign_out_for_real
      end
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    # An operator inside a support session is the one visitor the first gate
    # steps aside for, so that the support-session rule can refuse and audit
    # the write (spec/golden/impersonation_spec.rb sweeps that). The page
    # itself stays a 404 for them unless they are on the list.
    it 'stays a 404 for an operator in a support session, and refuses their writes as a support session does' do
      operator = create(:user, account: create(:account, :operator), platform_operator: true)
      operator.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)
      customer = create(:user)

      sign_in(operator)
      post operator_impersonations_path,
           params: { account_id: customer.account_id, user_id: customer.id,
                     mode: SupportImpersonation::READ_ONLY_MODE, reason: 'Looking into a billing question',
                     otp_attempt: operator.reload.current_otp }

      expect(request.session[SupportImpersonation::SESSION_KEY]).to be_present
      expect { get '/admin' }.to raise_error(ActionController::RoutingError)

      post '/admin/tiktok', params: { followers: '5' }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(MarketingSocialSnapshot.count).to eq(0)
    end

    it 'shows the link in the navigation to listed users only' do
      sign_in(stranger)
      get settings_profile_index_path

      expect(response.body).not_to include('marketing_admin_button')

      sign_out_for_real
      sign_in_with_password(luis)
      get settings_profile_index_path

      expect(response.body).to include('marketing_admin_button')
    end

    it 'is never offered to search engines' do
      sign_in_with_password(luis)

      get '/admin'

      expect(page.at_css('meta[name="robots"]')['content']).to eq('noindex')
      expect(Rails.public_path.join('robots.txt').read).not_to include('admin')
      expect(Rails.public_path.join('sitemap.xml').read).not_to include('/admin')
    end
  end

  describe 'with nothing set up yet' do
    before do
      sign_in_with_password(luis)

      get '/admin'
    end

    it 'says "Not connected yet" on every app, as a state rather than an error' do
      %w[youtube facebook instagram tiktok].each do |platform|
        expect(channel(platform)['data-state']).to eq('not_connected')
        expect(channel(platform).text).to include('Not connected yet')
      end

      expect(page.at_css('[data-channels-hint]').text).to include('None of the apps are connected yet')
      expect(page.css('[data-section-error]')).to be_empty
      expect(response.body).not_to include('Refresh now')
    end

    it 'shows honest empty states for the website and outreach' do
      expect(page.at_css('[data-empty="views"]').text).to include('Nothing counted yet')
      expect(page.at_css('[data-empty="breakdowns"]')).to be_present
      expect(page.at_css('[data-empty="campaigns"]')).to be_present
      expect(page.at_css('[data-empty="outreach"]').text).to include('Not connected yet')
      expect(page.at_css('[data-empty="posts"]')).to be_present
    end

    it 'never prints a credential variable or its value' do
      connect_youtube!
      connect_meta!

      get '/admin'

      expect(response.body).not_to include('youtube-api-key-value', 'meta-page-token-value', 'MARKETING_')
    end
  end

  describe 'the channel cards' do
    before do
      sign_in_with_password(luis)
      connect_youtube!
      connect_meta!
    end

    it 'says an app is connected and waiting before its first numbers arrive' do
      get '/admin'

      expect(channel('youtube')['data-state']).to eq('waiting')
      expect(channel('youtube').text).to include('The first numbers arrive with the next morning check')
      expect(response.body).to include('Refresh now')
    end

    it 'says when the history starts on the first day and shows the change once there is more' do
      snapshot!('youtube', day: today, followers: 212, total_views: 1800, post_count: 4)
      snapshot!('facebook', day: today - 9, followers: 80)
      snapshot!('facebook', day: today - 7, followers: 90)
      snapshot!('facebook', day: today, followers: 96)
      snapshot!('instagram', day: today - 3, followers: 150)
      snapshot!('instagram', day: today, followers: 148)

      get '/admin'

      expect(channel('youtube').at_css('[data-followers]').text).to eq('212')
      expect(channel('youtube').at_css('[data-history-starts]').text)
        .to include("History starts #{today.strftime('%b %-d')}")
      expect(channel('youtube').text).to include('The trend line starts after a second day')
      expect(channel('facebook').at_css('[data-change]').text.squish).to eq('+6 in 7 days')
      expect(channel('facebook').at_css('svg polyline')).to be_present
      expect(channel('instagram').at_css('[data-change]').text.squish)
        .to eq("−2 since #{(today - 3).strftime('%b %-d')}")
    end

    # Typed in a fortnight apart: the change is real, but it is not a week's.
    it 'names the day it is comparing with when that day is not seven days back' do
      snapshot!('tiktok', day: today - 14, followers: 100, total_views: 2000, collected_by: 'manual')
      snapshot!('tiktok', day: today, followers: 130, total_views: 2600, collected_by: 'manual')

      get '/admin'

      since = (today - 14).strftime('%b %-d')

      expect(channel('tiktok').at_css('[data-change]').text.squish).to eq("+30 since #{since}")
      expect(channel('tiktok').at_css('[data-views-change]').text.squish).to eq("+600 since #{since}")
      expect(channel('tiktok').text).not_to include('in 7 days')
    end

    it 'keeps showing an app’s last numbers, with the date and year, when they are months old' do
      old = today - 400
      snapshot!('youtube', day: old, followers: 180, total_views: 5000)
      MarketingSocialStatus.create!(platform: 'youtube', state: 'error', last_attempt_at: Time.current,
                                    error: '403: quota exceeded')

      get '/admin'

      expect(channel('youtube')['data-state']).to eq('ok')
      expect(channel('youtube').at_css('[data-followers]').text).to eq('180')
      expect(channel('youtube').at_css('[data-channel-note]').text)
        .to include("Showing the numbers from #{old.strftime('%b %-d, %Y')}")
      expect(channel('youtube').text).not_to include('The first numbers arrive')
    end

    # Today's check came back with likes and no views. The card shows likes;
    # last week's rise in VIEWS has no business next to that number.
    it 'shows no change beside a number the latest snapshot does not have' do
      snapshot!('youtube', day: today - 8, followers: 200, total_views: 1000)
      snapshot!('youtube', day: today - 1, followers: 210, total_views: 1500)
      snapshot!('youtube', day: today, followers: nil, total_views: nil, total_likes: 40)

      get '/admin'

      expect(channel('youtube').text).to include('Likes', '40', 'subscribers hidden by YouTube')
      expect(channel('youtube').at_css('[data-views-change]')).to be_nil
      expect(channel('youtube').at_css('[data-change]')).to be_nil
      expect(channel('youtube').text).not_to include('+500', '+10')
    end

    it 'labels Instagram and Facebook views as recent posts and shows no change for them' do
      snapshot!('instagram', day: today - 7, followers: 140, total_views: 9000)
      snapshot!('instagram', day: today, followers: 148, total_views: 4000)
      snapshot!('youtube', day: today - 7, followers: 200, total_views: 1000)
      snapshot!('youtube', day: today, followers: 212, total_views: 1500)

      get '/admin'

      expect(channel('instagram').text).to include('Views, recent posts', '4,000')
      expect(channel('instagram').at_css('[data-views-note]').text)
        .to eq('Added up from the newest 12 posts, not a running total.')
      expect(channel('instagram').at_css('[data-views-change]')).to be_nil
      expect(channel('instagram').at_css('[data-change]').text.squish).to eq('+8 in 7 days')
      expect(channel('youtube').at_css('[data-views-change]').text.squish).to eq('+500 in 7 days')
      expect(channel('youtube').at_css('[data-views-note]')).to be_nil
    end

    it 'marks only the failing app when a check fails, and keeps its last good numbers' do
      snapshot!('youtube', day: today - 1, followers: 330)
      snapshot!('facebook', day: today, followers: 96)
      MarketingSocialStatus.create!(platform: 'youtube', state: 'error', last_attempt_at: Time.current,
                                    error: '400: API key not valid. Please pass a valid API key.')
      MarketingSocialStatus.create!(platform: 'facebook', state: 'ok', last_attempt_at: Time.current,
                                    last_success_at: Time.current)

      get '/admin'

      expect(channel('youtube')['data-state']).to eq('ok')
      expect(channel('youtube').text).to include('Last check failed')
      expect(channel('youtube').at_css('[data-followers]').text).to eq('330')
      expect(channel('youtube').at_css('[data-channel-note]').text)
        .to include('API key not valid', "Showing the numbers from #{(today - 1).strftime('%b %-d')}")
      expect(channel('facebook').text).not_to include('failed', 'Problem')
      expect(channel('facebook').at_css('[data-channel-note]')).to be_nil
    end

    it 'says it could not check when the very first check fails' do
      MarketingSocialStatus.create!(platform: 'instagram', state: 'error', last_attempt_at: Time.current,
                                    error: '401: Invalid OAuth access token')

      get '/admin'

      expect(channel('instagram')['data-state']).to eq('error')
      expect(channel('instagram').text).to include('Couldn’t check', 'Invalid OAuth access token',
                                                   'The other apps are not affected')
      expect(channel('youtube')['data-state']).to eq('waiting')
    end

    it 'hides stored numbers again when an app is disconnected' do
      snapshot!('youtube', day: today, followers: 212)
      ENV.delete('MARKETING_YOUTUBE_API_KEY')

      get '/admin'

      expect(channel('youtube')['data-state']).to eq('not_connected')
      expect(channel('youtube').text).not_to include('212')
    end

    it 'lists the most-viewed posts across the apps' do
      snapshot!('youtube', day: today, followers: 212,
                           posts: [{ id: 'a', title: 'How to sign a PDF', url: 'https://youtube.test/a', views: 900,
                                     likes: 40, comments: 3 }])
      snapshot!('instagram', day: today, followers: 148,
                             posts: [{ id: 'b', title: 'Three taps', url: 'javascript:alert(1)', views: 1200,
                                       likes: nil, comments: 2 }])

      get '/admin'

      posts = page.css('[data-card="top-posts"] li')

      expect(posts.map do |post|
        post.text.squish
      end).to match([a_string_including('Three taps', 'Instagram', '1,200 views'),
                     a_string_including('How to sign a PDF', '900 views')])
      # Only an https address from the app becomes a link.
      expect(page.css('[data-card="top-posts"] a').pluck('href')).to eq(['https://youtube.test/a'])
    end
  end

  describe 'POST /admin/refresh' do
    before { sign_in_with_password(luis) }

    it 'has nothing to check until an app is connected' do
      post '/admin/refresh'

      expect(response).to redirect_to('/admin#channels')
      expect(flash[:alert]).to include('No apps are connected yet')
      expect(enqueued_checks).to be_empty
    end

    it 'checks every app in the background, once every ten minutes for everybody' do
      connect_youtube!

      post '/admin/refresh'

      expect(flash[:notice]).to include('Checking each app now')
      expect(enqueued_checks).to eq([['manual']])

      post '/admin/refresh'

      expect(flash[:alert]).to match(/Checked a few minutes ago\. Try again in 10 minutes\./)
      expect(enqueued_checks.size).to eq(1)

      get '/admin'

      expect(page.at_css('form[action="/admin/refresh"] button')['disabled']).to be_present
      expect(response.body).to include('Ready again in 10 min')

      travel_to(11.minutes.from_now) { post '/admin/refresh' }

      expect(enqueued_checks.size).to eq(2)
    end

    # ActiveJob rides on Sidekiq here, whose fake queue holds the wrapped job.
    def enqueued_checks
      Sidekiq::Queues['default'].select { |job| job['wrapped'] == 'MarketingSocialSnapshotJob' }
                                .map { |job| job['args'].first['arguments'] }
    end
  end

  describe 'POST /admin/tiktok' do
    before { sign_in_with_password(luis) }

    it 'stores the typed-in numbers as today’s TikTok snapshot and shows them' do
      post '/admin/tiktok', params: { followers: '1,305', post_count: '14', total_views: '', total_likes: '22 400' }

      expect(response).to redirect_to('/admin#channels')
      expect(MarketingSocialSnapshot.find_by!(platform: 'tiktok', day: today))
        .to have_attributes(followers: 1305, post_count: 14, total_views: nil, total_likes: 22_400,
                            collected_by: 'manual')

      follow_redirect!

      expect(channel('tiktok')['data-state']).to eq('ok')
      expect(channel('tiktok').at_css('[data-followers]').text).to eq('1,305')
      expect(channel('tiktok').text).to include('Typed in today')
    end

    it 'replaces the same day’s entry instead of adding a second one' do
      post '/admin/tiktok', params: { followers: '100' }
      post '/admin/tiktok', params: { followers: '104' }

      expect(MarketingSocialSnapshot.where(platform: 'tiktok').pluck(:followers)).to eq([104])
    end

    it 'refuses anything that is not a whole number, and changes nothing' do
      post '/admin/tiktok', params: { followers: 'lots' }

      expect(flash[:alert]).to eq('Use whole numbers only, with no letters.')

      post '/admin/tiktok', params: { followers: '', post_count: '3' }

      expect(flash[:alert]).to eq('Type in the follower count as a whole number.')
      expect(MarketingSocialSnapshot.count).to eq(0)
    end

    # The video count is a 32-bit column. A number that does not fit is
    # refused in words, not by the database with an error page.
    it 'refuses a number too large for its column, in a sentence, and stores nothing' do
      post '/admin/tiktok', params: { followers: '100', post_count: '2,147,483,648' }

      expect(response).to redirect_to('/admin#channels')
      expect(flash[:alert]).to eq('Videos can be at most 2,147,483,647.')

      post '/admin/tiktok', params: { followers: '100,000,000,001' }

      expect(flash[:alert]).to eq('Followers can be at most 100,000,000,000.')

      post '/admin/tiktok', params: { followers: '9' * 40 }

      expect(flash[:alert]).to eq('Use whole numbers only, with no letters.')
      expect(MarketingSocialSnapshot.count).to eq(0)
    end

    it 'stores the largest number each field takes' do
      limits = MarketingAdmin::Social::ENTRY_FIELDS.transform_values(&:last)

      post '/admin/tiktok', params: limits.transform_values(&:to_s)

      expect(flash[:notice]).to be_present
      expect(MarketingSocialSnapshot.find_by!(platform: 'tiktok')).to have_attributes(limits)

      # And no cap is larger than its column can hold.
      limits.each do |column, limit|
        bytes = MarketingSocialSnapshot.columns_hash.fetch(column.to_s).limit || 4

        expect(limit).to be <= (2**((bytes * 8) - 1)) - 1, "#{column} takes #{limit}"
      end
    end

    it 'asks for fresh numbers once the last entry is more than a week old' do
      snapshot!('tiktok', day: today - 9, followers: 61, collected_by: 'manual')

      get '/admin'

      expect(channel('tiktok').at_css('[data-channel-note]').text).to include('Time for this week’s numbers')
    end
  end

  describe 'the numbers' do
    before { sign_in_with_password(luis) }

    it 'shows page views, where they came from, campaign tags and sign-up interest for the chosen period' do
      { [today, 'view', '/', 'google', '', 'mobile'] => 40,
        [today, 'view', '/pricing', 'youtube', 'yt-how-to-sign', 'desktop'] => 10,
        [today, 'signup_open', '/pricing', 'youtube', 'yt-how-to-sign', 'desktop'] => 4,
        [today, 'signup', '/sign_up', 'youtube', 'yt-how-to-sign', 'desktop'] => 1,
        [today - 10, 'view', '/help', 'reddit', '',
         'tablet'] => 50 }.each do |(day, event, path, source, campaign, device), count|
        MarketingPageCount.insert!({ day:, event:, path:, source:, campaign:, device:, count: })
      end

      get '/admin', params: { range: 7 }

      expect(page.at_css('[data-figure="page-views-today"] dd').text).to eq('50')
      expect(page.at_css('[data-figure="last-30-days"] dd').text).to eq('100')
      expect(page.at_css('[data-rank="pages"]').text.squish).to include('Home page 40 80%', '/pricing 10 20%')
      expect(page.at_css('[data-rank="pages"]').text).not_to include('/help')
      expect(page.at_css('[data-rank="where-visits-came-from"]').text.squish).to include('Google 40 80%',
                                                                                         'YouTube 10 20%')
      expect(page.at_css('[data-rank="devices"]').text.squish).to include('Phone 40 80%', 'Computer 10 20%')
      expect(page.at_css('[data-card="campaigns"] tbody tr').text.squish).to eq('yt-how-to-sign YouTube 10 4 1')
      expect(page.at_css('[data-card="signup-opens"]').text.squish)
        .to include('8 for every 100 page views', '/pricing 4')
      expect(page.at_css('[data-history-starts]').text).to include("History starts #{(today - 10).strftime('%b %-d')}")
    end

    it 'falls back to thirty days when the period is not one it offers' do
      get '/admin', params: { range: 9999 }

      expect(page.at_css('[aria-current="true"]').text).to eq('Last 30 days')
    end

    it 'shows what the outreach jobs reported' do
      MarketingOutreachCount.create!(day: today, kind: 'emails_sent', count: 24)
      MarketingOutreachCount.create!(day: today - 8, kind: 'emails_sent', count: 9)
      MarketingOutreachCount.create!(day: today, kind: 'reddit_comments', count: 3)

      get '/admin'

      expect(page.at_css('[data-outreach-kind="emails_sent"]').text.squish)
        .to eq('Emails sent 24 in 7 days, 9 the week before')
      expect(page.at_css('[data-card="outreach-days"] tbody tr').text.squish).to eq('Today 24 — 3 —')
    end

    it 'shows new accounts, paid plans and documents' do
      account = create(:account)
      create(:account_subscription, account:, access_state: 'active', stripe_subscription_id: 'sub_123')
      author = create(:user, account:)
      submission = create(:submission, template: create(:template, account:, author:), created_by_user: author)
      create(:submitter, submission:, account_id: account.id, uuid: SecureRandom.uuid, completed_at: Time.current)

      get '/admin'

      expect(page.at_css('[data-figure="paid-plans-now"] dd').text).to eq('1')
      expect(page.at_css('[data-figure="new-paid-plans-last-7-days"]').text.squish)
        .to eq('New paid plans, last 7 days 0 Subscriptions created in these 7 days, even if they have ended since')
      expect(page.at_css('[data-product-row="sent"]').text.squish).to include('1 today')
      expect(page.at_css('[data-product-row="completed"]').text.squish).to include('1 today')
    end

    # The production image builds the stylesheet from app/views and
    # app/javascript only (Dockerfile), so a class named in the helper would
    # be missing from the shipped CSS: the chart's columns would have no
    # colour at all. The helper answers with words and the views pick classes.
    it 'names every CSS class in a view, where the production stylesheet build can see it' do
      helper = Rails.root.join('app/helpers/marketing_admin_helper.rb').read
      dockerfile = Rails.root.join('Dockerfile').read

      expect(dockerfile).to include('COPY ./app/views ./app/views')
      expect(dockerfile).not_to include('COPY ./app/helpers')
      expect(helper.scan(/'[^']*\b(?:bg|text|border|fill|stroke)-[a-z]+[^']*'/)).to be_empty

      { today => 5, today - 1 => 9 }.each do |day, count|
        MarketingPageCount.insert!({ day:, event: 'view', path: '/', source: 'direct', campaign: '',
                                     device: 'desktop', count: })
      end

      get '/admin'

      columns = page.css('[data-card="daily-views"] .mka-column span').to_a.last(2)

      expect(columns.pluck('class')).to eq(%w[bg-neutral/75 bg-indigo-600])
    end

    it 'keeps the rest of the page when one section cannot be read' do
      allow(MarketingAdmin::Product).to receive(:report).and_raise(ActiveRecord::StatementInvalid, 'boom')
      allow(ErrorReport).to receive(:error)

      get '/admin'

      expect(response).to have_http_status(:ok)
      expect(page.at_css('[data-section="product"] [data-section-error]').text).to include('couldn’t be loaded')
      expect(page.at_css('[data-section="website"] [data-section-error]')).to be_nil
      expect(page.at_css('[data-section="channels"]').text).to include('Not connected yet')
      expect(ErrorReport).to have_received(:error).with(an_instance_of(ActiveRecord::StatementInvalid))
    end
  end
end
