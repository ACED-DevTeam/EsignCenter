# frozen_string_literal: true

# The social checks behind the "Channels" section of /admin. Nothing here
# touches a real app: WebMock stands in for YouTube and Meta.
RSpec.describe MarketingAdmin::Social do
  stash_env 'MARKETING_YOUTUBE_CHANNEL_ID', 'MARKETING_YOUTUBE_API_KEY', 'MARKETING_YOUTUBE_OAUTH_CLIENT_ID',
            'MARKETING_YOUTUBE_OAUTH_CLIENT_SECRET', 'MARKETING_YOUTUBE_OAUTH_REFRESH_TOKEN',
            'MARKETING_META_PAGE_TOKEN', 'MARKETING_FACEBOOK_PAGE_ID', 'MARKETING_INSTAGRAM_USER_ID', clear: true

  let(:youtube_key) { 'AIzaSyD-youtube-api-key-0123456789abcdefg' }
  let(:meta_token) { 'EAAGm0PX4ZCpsBAmetaPageToken0123456789' }
  let(:today) { MarketingAdmin.today }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:graph) { 'https://graph.facebook.com/v25.0' }

  def connect_youtube!
    ENV['MARKETING_YOUTUBE_CHANNEL_ID'] = 'UCchannel'
    ENV['MARKETING_YOUTUBE_API_KEY'] = youtube_key
  end

  def connect_meta!
    ENV['MARKETING_META_PAGE_TOKEN'] = meta_token
    ENV['MARKETING_FACEBOOK_PAGE_ID'] = '1000'
    ENV['MARKETING_INSTAGRAM_USER_ID'] = '2000'
  end

  def answer(body, status: 200)
    { status:, headers: json, body: body.to_json }
  end

  def stub_youtube(subscribers: '337', videos: '2', hidden: false)
    channel = { snippet: { title: 'EsignCenter' },
                statistics: { subscriberCount: subscribers, viewCount: '1500', videoCount: videos,
                              hiddenSubscriberCount: hidden },
                contentDetails: { relatedPlaylists: { uploads: 'UUuploads' } } }
    uploads = %w[v1 v2].map { |id| { contentDetails: { videoId: id } } }
    videos = [
      { id: 'v1', snippet: { title: 'How to sign a PDF', publishedAt: '2026-11-10T15:00:00Z' },
        statistics: { viewCount: '1200', likeCount: '40', commentCount: '3' } },
      { id: 'v2', snippet: { title: 'Send a lease', publishedAt: '2026-11-15T15:00:00Z' },
        statistics: { viewCount: '900', likeCount: '25' } }
    ]

    stub_request(:get, 'https://www.googleapis.com/youtube/v3/channels')
      .with(query: hash_including('id' => 'UCchannel')).to_return(answer({ items: [channel] }))
    stub_request(:get, 'https://www.googleapis.com/youtube/v3/playlistItems')
      .with(query: hash_including('playlistId' => 'UUuploads')).to_return(answer({ items: uploads }))
    stub_request(:get, 'https://www.googleapis.com/youtube/v3/videos')
      .with(query: hash_including('id' => 'v1,v2')).to_return(answer({ items: videos }))
  end

  def stub_graph(path, body, status: 200)
    stub_request(:get, "#{graph}/#{path}").with(query: hash_including({})).to_return(answer(body, status:))
  end

  def stub_facebook
    stub_graph('1000', { name: 'EsignCenter', followers_count: 133, fan_count: 120 })
    stub_graph('1000/video_reels', { data: [{ id: '501', description: 'Sign on any device',
                                              created_time: '2026-11-16T15:00:00+0000',
                                              permalink_url: '/reel/501' }] })
    insights = { data: [
      { name: 'fb_reels_total_plays', values: [{ value: 2795 }] },
      { name: 'post_video_likes_by_reaction_type', values: [{ value: { like: 120, love: 13 } }] },
      { name: 'post_video_social_actions', values: [{ value: { COMMENT: 17, SHARE: 4 } }] }
    ] }
    stub_request(:post, 'https://graph.facebook.com/').to_return(answer([{ code: 200, body: insights.to_json }]))
  end

  def stub_instagram
    stub_graph('2000', { username: 'esigncenter', followers_count: 173, media_count: 19 })
    stub_graph('2000/media', { data: [
                 { id: '901', caption: "Three taps\nto sign", media_product_type: 'REELS',
                   permalink: 'https://www.instagram.com/reel/901', timestamp: '2026-11-16T15:00:00+0000',
                   like_count: 212, comments_count: 28 },
                 { id: '902', media_product_type: 'FEED', like_count: 9, comments_count: 0 }
               ] })
    stub_graph('901/insights', { data: [{ name: 'views', total_value: { value: 4455 } }] })
    stub_graph('902/insights', { error: { message: 'No insights for this media' } }, status: 400)
  end

  describe 'connection' do
    it 'treats an app with no credentials as not connected, and makes no request for it' do
      expect(described_class.run!).to eq('youtube' => :not_connected, 'facebook' => :not_connected,
                                         'instagram' => :not_connected)
      expect(MarketingSocialStatus.count).to eq(0)
      expect(a_request(:any, //)).not_to have_been_made
      expect(described_class.report[:cards].pluck(:state)).to all(eq(:not_connected))
    end

    it 'needs every piece of a credential, and ignores a slot still holding its paste marker' do
      ENV['MARKETING_YOUTUBE_CHANNEL_ID'] = 'UCchannel'

      expect(described_class.connected?('youtube')).to be(false)

      ENV['MARKETING_YOUTUBE_API_KEY'] = 'PASTE_YOUTUBE_KEY_HERE'

      expect(described_class.connected?('youtube')).to be(false)

      ENV['MARKETING_YOUTUBE_API_KEY'] = youtube_key
      ENV['MARKETING_META_PAGE_TOKEN'] = meta_token

      expect(described_class.connected?('youtube')).to be(true)
      # The Page token alone connects neither Meta app: each needs its own id.
      expect(described_class.connected?('facebook')).to be(false)
      expect(described_class.connected?('instagram')).to be(false)
    end
  end

  describe 'YouTube' do
    before { connect_youtube! }

    it 'stores subscribers, views, video count and the most-viewed videos' do
      stub_youtube

      expect(described_class.check!('youtube', trigger: 'cron')).to eq(:ok)

      snapshot = MarketingSocialSnapshot.find_by!(platform: 'youtube', day: today)

      # The per-video total (2,100) beats the channel-wide count (1,500), which lags.
      expect(snapshot).to have_attributes(followers: 337, total_views: 2100, total_likes: 65, post_count: 2,
                                          account_name: 'EsignCenter', collected_by: 'api')
      expect(snapshot.posts.pluck('title', 'views', 'comments', 'url'))
        .to eq([['How to sign a PDF', 1200, 3, 'https://www.youtube.com/watch?v=v1'],
                ['Send a lease', 900, nil, 'https://www.youtube.com/watch?v=v2']])
      expect(MarketingSocialStatus.find_by!(platform: 'youtube'))
        .to have_attributes(state: 'ok', error: nil, triggered_by: 'cron')
    end

    it 'sends the key in a header, never in the address' do
      stub_youtube

      described_class.check!('youtube', trigger: 'cron')

      expect(a_request(:get, %r{googleapis\.com/youtube/v3/channels})
        .with(headers: { 'X-Goog-Api-Key' => youtube_key })).to have_been_made
      expect(a_request(:any, /#{Regexp.escape(youtube_key)}/)).not_to have_been_made
    end

    it 'keeps a hidden subscriber count as unknown, not zero' do
      stub_youtube(hidden: true)

      described_class.check!('youtube', trigger: 'cron')

      expect(MarketingSocialSnapshot.last.followers).to be_nil
    end

    it 'reads a brand-new channel with no videos as zero videos rather than an error' do
      stub_youtube(videos: '0')

      expect(described_class.check!('youtube', trigger: 'cron')).to eq(:ok)
      expect(MarketingSocialSnapshot.last).to have_attributes(post_count: 0, posts: [])
      expect(a_request(:get, /playlistItems/)).not_to have_been_made
    end

    it 'uses the owner sign-in when there is no API key' do
      ENV.delete('MARKETING_YOUTUBE_API_KEY')
      ENV['MARKETING_YOUTUBE_OAUTH_CLIENT_ID'] = 'client-id'
      ENV['MARKETING_YOUTUBE_OAUTH_CLIENT_SECRET'] = 'client-secret-value'
      ENV['MARKETING_YOUTUBE_OAUTH_REFRESH_TOKEN'] = '1//refresh-token-value-0123456789'
      stub_request(:post, 'https://oauth2.googleapis.com/token')
        .to_return(answer({ access_token: 'ya29.short-lived-token' }))
      stub_youtube

      expect(described_class.check!('youtube', trigger: 'cron')).to eq(:ok)
      expect(a_request(:get, /channels/).with(headers: { 'Authorization' => 'Bearer ya29.short-lived-token' }))
        .to have_been_made
    end
  end

  describe 'Facebook and Instagram' do
    before { connect_meta! }

    it 'stores the Page’s followers and each reel’s plays' do
      stub_facebook

      expect(described_class.check!('facebook', trigger: 'cron')).to eq(:ok)
      expect(MarketingSocialSnapshot.find_by!(platform: 'facebook'))
        .to have_attributes(followers: 133, total_views: 2795, total_likes: 133, post_count: 1,
                            account_name: 'EsignCenter')
      expect(MarketingSocialSnapshot.last.posts.first)
        .to include('title' => 'Sign on any device', 'views' => 2795, 'comments' => 17,
                    'url' => 'https://www.facebook.com/reel/501')
    end

    it 'keeps the reels without numbers when the plays cannot be read' do
      stub_facebook
      stub_request(:post, 'https://graph.facebook.com/').to_return(status: 500, body: 'oops')

      expect(described_class.check!('facebook', trigger: 'cron')).to eq(:ok)
      expect(MarketingSocialSnapshot.last).to have_attributes(followers: 133, total_views: nil, post_count: 1)
    end

    it 'stores the Instagram account’s followers, posts and the views it can get' do
      stub_instagram

      expect(described_class.check!('instagram', trigger: 'cron')).to eq(:ok)
      expect(MarketingSocialSnapshot.find_by!(platform: 'instagram'))
        .to have_attributes(followers: 173, total_views: 4455, total_likes: 221, post_count: 19,
                            account_name: '@esigncenter')
      expect(MarketingSocialSnapshot.last.posts.pluck('title', 'views'))
        .to eq([['Three taps to sign', 4455], ['Instagram post', nil]])
    end

    it 'sends the Page token in a header, never in the address or the form' do
      stub_facebook
      stub_instagram

      described_class.run!

      sent_token = { 'Authorization' => "Bearer #{meta_token}" }

      expect(a_request(:get, "#{graph}/1000").with(query: hash_including({}), headers: sent_token)).to have_been_made
      expect(a_request(:any, /#{meta_token}/)).not_to have_been_made
      expect(a_request(:post, 'https://graph.facebook.com/').with { |request| request.body.include?(meta_token) })
        .not_to have_been_made
    end
  end

  describe 'when a check fails' do
    before do
      connect_youtube!
      connect_meta!
    end

    it 'marks only the app that failed and still checks the others' do
      stub_request(:get, /googleapis\.com/)
        .to_return(answer({ error: { message: 'API key not valid. Please pass a valid API key.' } }, status: 400))
      stub_facebook
      stub_instagram

      expect(described_class.run!(trigger: 'manual'))
        .to eq('youtube' => :error, 'facebook' => :ok, 'instagram' => :ok)
      expect(MarketingSocialStatus.find_by!(platform: 'youtube'))
        .to have_attributes(state: 'error', error: '400: API key not valid. Please pass a valid API key.',
                            triggered_by: 'manual', last_success_at: nil)
      expect(MarketingSocialStatus.where(state: 'ok').pluck(:platform)).to contain_exactly('facebook', 'instagram')
      expect(MarketingSocialSnapshot.pluck(:platform)).to contain_exactly('facebook', 'instagram')
    end

    it 'keeps yesterday’s numbers and the time of the last good check' do
      stub_youtube
      travel_to(1.day.ago) { described_class.check!('youtube', trigger: 'cron') }
      good_at = MarketingSocialStatus.find_by!(platform: 'youtube').last_success_at
      stub_request(:get, /googleapis\.com/).to_timeout

      expect(described_class.check!('youtube', trigger: 'cron')).to eq(:error)

      card = described_class.report[:cards].find { |c| c[:platform] == 'youtube' }

      expect(card).to include(state: :ok, stale: true)
      expect(card[:problem]).to include('Could not reach the app')
      expect(card[:latest]).to have_attributes(followers: 337, day: today - 1)
      expect(MarketingSocialStatus.find_by!(platform: 'youtube').last_success_at).to eq(good_at)
    end

    it 'never stores, shows or logs a credential an app echoes back' do
      leak = "Bad token #{meta_token} for key=#{youtube_key} and access_token=abc123456789"
      stub_request(:get, /graph\.facebook\.com/).to_return(answer({ error: { message: leak } }, status: 401))
      stub_request(:get, /googleapis\.com/).to_return(answer({ error: { message: leak } }, status: 403))
      allow(Rails.logger).to receive(:warn).and_call_original

      described_class.run!

      stored = MarketingSocialStatus.pluck(:error).join(' ')

      expect(stored).to include('401: Bad token', '403: Bad token')
      expect(stored).not_to include(meta_token, youtube_key, 'abc123456789')
      expect(Rails.logger).not_to have_received(:warn)
        .with(a_string_matching(/#{meta_token}|#{Regexp.escape(youtube_key)}/))
    end

    it 'does not show the wording of a bug in our own code' do
      allow(MarketingAdmin::Social::Youtube).to receive(:fetch).and_raise(NoMethodError,
                                                                          'undefined method secret_thing')
      allow(ErrorReport).to receive(:error)

      expect(described_class.check!('youtube', trigger: 'cron')).to eq(:error)
      expect(MarketingSocialStatus.find_by!(platform: 'youtube').error)
        .to eq('Something went wrong on our side while checking.')
      expect(ErrorReport).to have_received(:error).with(an_instance_of(NoMethodError), platform: 'youtube')
    end

    it 'stops an adapter that asks for more requests than its allowance' do
      http = MarketingAdmin::Social::Http.new(budget: 1)
      stub_request(:get, 'https://example.test/a').to_return(status: 200, headers: json, body: '{}')

      http.get('https://example.test/a')

      expect { http.get('https://example.test/a') }.to raise_error(MarketingAdmin::Social::Error, /too many requests/)
      expect(a_request(:get, 'https://example.test/a')).to have_been_made.once
    end
  end

  # A card keeps its last good numbers, dated, for as long as there are any.
  describe 'an app whose numbers are old' do
    def card(platform)
      described_class.report[:cards].find { |c| c[:platform] == platform }
    end

    def snapshot!(platform, ago, followers, **attributes)
      MarketingSocialSnapshot.create!({ platform:, day: today - ago, followers:, collected_by: 'api',
                                        fetched_at: Time.current, posts: [] }.merge(attributes))
    end

    before do
      connect_youtube!
      connect_meta!
    end

    it 'still shows the last snapshot, with its date, when the newest one is months old' do
      snapshot!('youtube', 200, 150)
      snapshot!('youtube', 95, 180, total_views: 5000, posts: [{ id: 'v', title: 'An old video', views: 900 }])
      MarketingSocialStatus.create!(platform: 'youtube', state: 'error', last_attempt_at: Time.current,
                                    error: '403: The request cannot be completed because you have exceeded your quota.')

      youtube = card('youtube')

      expect(youtube).to include(state: :ok, stale: true, change: nil, views_change: nil,
                                 history_starts: today - 200, series: [])
      expect(youtube[:latest]).to have_attributes(followers: 180, day: today - 95, total_views: 5000)
      expect(youtube[:problem]).to include('exceeded your quota')
      # Its posts are still the latest we know of.
      expect(described_class.report[:top_posts].pluck(:title)).to eq(['An old video'])
    end

    it 'goes on showing an old typed-in TikTok number, and asks for a new one' do
      snapshot!('tiktok', 120, 61, collected_by: 'manual')

      expect(card('tiktok')).to include(state: :ok, entry_due: true)
      expect(card('tiktok')[:latest]).to have_attributes(followers: 61, day: today - 120)
    end

    it 'draws the chart and the change from the last sixty days only, and names the true first day' do
      snapshot!('instagram', 300, 10)
      snapshot!('instagram', 7, 140)
      snapshot!('instagram', 0, 148)

      instagram = card('instagram')

      expect(instagram[:change]).to eq(value: 8, since: today - 7, exact: true)
      expect(instagram[:series].map(&:day)).to eq([today - 7, today])
      expect(instagram[:history_starts]).to eq(today - 300)
    end

    it 'ignores a snapshot dated in the future, and still says "not connected" for an app that is not' do
      snapshot!('facebook', -3, 999)
      snapshot!('facebook', 90, 96)
      ENV.delete('MARKETING_INSTAGRAM_USER_ID')
      snapshot!('instagram', 90, 148)

      expect(card('facebook')[:latest]).to have_attributes(followers: 96)
      expect(card('instagram')).to include(state: :not_connected, latest: nil, history_starts: nil)
    end
  end

  describe 'one snapshot per app per Chicago day' do
    before { connect_youtube! }

    it 'replaces the day’s snapshot on a second check and starts a new one the next day' do
      stub_youtube(subscribers: '337')
      travel_to(Time.utc(2026, 11, 21, 12, 0)) { described_class.check!('youtube', trigger: 'cron') }

      stub_youtube(subscribers: '340')
      # 03:30 UTC on the 22nd is still the evening of the 21st in Chicago.
      travel_to(Time.utc(2026, 11, 22, 3, 30)) { described_class.check!('youtube', trigger: 'manual') }

      expect(MarketingSocialSnapshot.pluck(:day, :followers)).to eq([[Date.new(2026, 11, 21), 340]])

      stub_youtube(subscribers: '345')
      travel_to(Time.utc(2026, 11, 22, 12, 0)) { described_class.check!('youtube', trigger: 'cron') }

      expect(MarketingSocialSnapshot.order(:day).pluck(:day, :followers))
        .to eq([[Date.new(2026, 11, 21), 340], [Date.new(2026, 11, 22), 345]])
    end
  end

  describe 'what the views number means' do
    def snapshots!(platform, pairs, collected_by: 'api')
      pairs.each do |ago, views|
        MarketingSocialSnapshot.create!(platform:, day: today - ago, followers: 100 + (10 - ago), total_views: views,
                                        collected_by:, fetched_at: Time.current, posts: [])
      end
    end

    def card(platform)
      described_class.report[:cards].find { |c| c[:platform] == platform }
    end

    before do
      connect_youtube!
      connect_meta!
    end

    it 'shows a change for a running total (YouTube, TikTok) and never for views added up from recent posts' do
      snapshots!('youtube', [[7, 1000], [0, 1500]])
      snapshots!('tiktok', [[7, 2000], [0, 2600]], collected_by: 'manual')
      # Instagram's sum FELL because an old post dropped off the list we read.
      snapshots!('instagram', [[7, 9000], [0, 4000]])
      snapshots!('facebook', [[7, 500], [0, 800]])

      expect(card('youtube')).to include(views_total: true, views_change: { value: 500, since: today - 7, exact: true })
      expect(card('tiktok')[:views_change]).to eq(value: 600, since: today - 7, exact: true)
      expect(card('instagram')).to include(views_total: false, views_change: nil, views: 'Views, recent posts')
      expect(card('instagram')[:views_note]).to eq('Added up from the newest 12 posts, not a running total.')
      expect(card('facebook')).to include(views_total: false, views_change: nil, views: 'Plays, recent reels')
      expect(card('facebook')[:views_note]).to eq('Added up from the newest 40 reels, not a running total.')
      # Followers are a real total on every app.
      expect(card('instagram')[:change]).to include(exact: true)
    end
  end

  describe '.change_over' do
    def rows(pairs)
      pairs.map { |ago, followers| MarketingSocialSnapshot.new(day: today - ago, followers:) }
    end

    it 'compares with the snapshot from seven days back' do
      expect(described_class.change_over(rows([[9, 80], [7, 90], [3, 95], [0, 96]]), 7, :followers))
        .to eq(value: 6, since: today - 7, exact: true)
    end

    it 'compares with the oldest snapshot, and says so, when there is less than a week of history' do
      expect(described_class.change_over(rows([[3, 150], [0, 148]]), 7, :followers))
        .to eq(value: -2, since: today - 3, exact: false)
    end

    # TikTok typed in a fortnight apart, or a week of failed checks: the only
    # snapshot old enough is OLDER than seven days, and the change must not be
    # presented as a week's.
    # The card shows the LATEST snapshot. If that one came back without the
    # number, there is nothing on the card for a change to sit next to.
    it 'has nothing to say when the snapshot being shown does not have that number' do
      latest_without = [MarketingSocialSnapshot.new(day: today - 8, total_views: 1000),
                        MarketingSocialSnapshot.new(day: today - 1, total_views: 1500),
                        MarketingSocialSnapshot.new(day: today, total_views: nil, total_likes: 40)]

      expect(described_class.change_over(latest_without, 7, :total_views)).to be_nil
      expect(described_class.change_over(rows([[8, 300], [1, 310], [0, nil]]), 7, :followers)).to be_nil
      expect(described_class.change_over([], 7, :followers)).to be_nil
    end

    it 'compares with a snapshot that has the number, skipping ones in between that do not' do
      expect(described_class.change_over(rows([[7, 100], [3, nil], [0, 130]]), 7, :followers))
        .to eq(value: 30, since: today - 7, exact: true)
    end

    it 'says so when the nearest earlier snapshot is older than seven days' do
      expect(described_class.change_over(rows([[14, 100], [0, 130]]), 7, :followers))
        .to eq(value: 30, since: today - 14, exact: false)
      expect(described_class.change_over(rows([[20, 90], [9, 100], [0, 130]]), 7, :followers))
        .to eq(value: 30, since: today - 9, exact: false)
    end

    it 'has nothing to say with a single snapshot, or with numbers an app hides' do
      expect(described_class.change_over(rows([[0, 148]]), 7, :followers)).to be_nil
      expect(described_class.change_over(rows([[3, nil], [0, 148]]), 7, :followers)).to be_nil
    end
  end
end
