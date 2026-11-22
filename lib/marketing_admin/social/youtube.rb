# frozen_string_literal: true

module MarketingAdmin
  module Social
    # YouTube Data API v3: the channel's public numbers and each video's
    # views. An API key is enough; the owner sign-in (an OAuth refresh token)
    # is accepted instead for a channel that hides its subscriber count from
    # the public API. Up to four requests a check.
    module Youtube
      API = 'https://www.googleapis.com/youtube/v3'
      TOKEN_URL = 'https://oauth2.googleapis.com/token'
      CHANNEL_ENV = 'MARKETING_YOUTUBE_CHANNEL_ID'
      API_KEY_ENV = 'MARKETING_YOUTUBE_API_KEY'
      OAUTH_ENVS = %w[MARKETING_YOUTUBE_OAUTH_CLIENT_ID MARKETING_YOUTUBE_OAUTH_CLIENT_SECRET
                      MARKETING_YOUTUBE_OAUTH_REFRESH_TOKEN].freeze
      BUDGET = 4

      module_function

      def connected?
        Social.env(CHANNEL_ENV).present? && (Social.env(API_KEY_ENV).present? || oauth?)
      end

      def oauth?
        OAUTH_ENVS.all? { |name| Social.env(name).present? }
      end

      def fetch
        http = Http.new(budget: BUDGET, secrets: [Social.env(API_KEY_ENV), *OAUTH_ENVS.map { |name| Social.env(name) }])
        headers = auth_headers(http)
        channel = http.get("#{API}/channels", headers:,
                                              params: { part: 'snippet,statistics,contentDetails',
                                                        id: Social.env(CHANNEL_ENV) })['items']&.first

        raise Error, "YouTube couldn't find the channel. Check the channel ID." unless channel

        stats = channel['statistics'] || {}
        posts = videos(http, headers, channel, Social.int(stats['videoCount']))

        { account_name: channel.dig('snippet', 'title'),
          followers: stats['hiddenSubscriberCount'] ? nil : Social.int(stats['subscriberCount']),
          # The channel-wide view count lags behind the per-video counts; use whichever is higher.
          total_views: [Social.int(stats['viewCount']) || 0, Social.sum(posts, :views) || 0].max,
          total_likes: Social.sum(posts, :likes),
          post_count: Social.int(stats['videoCount']),
          posts: }
      end

      def auth_headers(http)
        return { 'X-Goog-Api-Key' => Social.env(API_KEY_ENV) } if Social.env(API_KEY_ENV).present?

        id, secret, refresh = OAUTH_ENVS.map { |name| Social.env(name) }
        token = http.post(TOKEN_URL, body: { client_id: id, client_secret: secret, refresh_token: refresh,
                                             grant_type: 'refresh_token' })['access_token']

        raise Error, 'Google did not accept the YouTube sign-in. It may need to be connected again.' if token.blank?

        { 'Authorization' => "Bearer #{token}" }
      end

      # A brand-new channel has no uploads yet, and YouTube answers 404 for
      # an empty uploads list: that is zero videos, not a failure.
      def videos(http, headers, channel, video_count)
        uploads = channel.dig('contentDetails', 'relatedPlaylists', 'uploads')

        return [] if uploads.blank? || video_count&.zero?

        ids = begin
          http.get("#{API}/playlistItems", headers:,
                                           params: { part: 'contentDetails', maxResults: 50, playlistId: uploads })
              .fetch('items', []).filter_map { |item| item.dig('contentDetails', 'videoId') }
        rescue Error => e
          raise unless e.status == 404

          []
        end

        return [] if ids.empty?

        http.get("#{API}/videos", headers:, params: { part: 'snippet,statistics', id: ids.join(',') })
            .fetch('items', []).map { |video| post(video) }
      end

      def post(video)
        stats = video['statistics'] || {}

        { id: video['id'], title: video.dig('snippet', 'title'),
          url: "https://www.youtube.com/watch?v=#{video['id']}",
          published_at: video.dig('snippet', 'publishedAt'),
          views: Social.int(stats['viewCount']), likes: Social.int(stats['likeCount']),
          comments: Social.int(stats['commentCount']) }
      end
    end
  end
end
