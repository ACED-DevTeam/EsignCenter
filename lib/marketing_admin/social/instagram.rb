# frozen_string_literal: true

module MarketingAdmin
  module Social
    # The Instagram business account linked to the Facebook Page, read with
    # the same Page token (permissions: instagram_basic,
    # instagram_manage_insights). The profile, the newest posts, and views
    # for the newest few (one request each, so only a dozen).
    module Instagram
      USER_ENV = 'MARKETING_INSTAGRAM_USER_ID'
      MEDIA_FIELDS = 'id,caption,media_product_type,permalink,timestamp,like_count,comments_count'
      INSIGHT_POSTS = 12
      BUDGET = 2 + INSIGHT_POSTS

      module_function

      def connected?
        Social.env(USER_ENV).present? && Social.env(Meta::TOKEN_ENV).present?
      end

      def fetch
        http = Meta.http(BUDGET)
        user_id = Social.env(USER_ENV)
        profile = http.get("#{Meta::BASE}/#{user_id}", headers: Meta.headers,
                                                       params: { fields: 'username,followers_count,media_count' })
        media = http.get("#{Meta::BASE}/#{user_id}/media", headers: Meta.headers,
                                                           params: { fields: MEDIA_FIELDS, limit: 50 })
        posts = media.fetch('data', []).first(50).each_with_index.map do |item, index|
          post(item).merge(index < INSIGHT_POSTS ? views(http, item['id']) : {})
        end

        { account_name: profile['username'].present? ? "@#{profile['username']}" : nil,
          followers: Social.int(profile['followers_count']),
          total_views: Social.sum(posts, :views), total_likes: Social.sum(posts, :likes),
          post_count: Social.int(profile['media_count']), posts: }
      end

      def post(item)
        kind = item['media_product_type'] == 'REELS' ? 'Instagram reel' : 'Instagram post'

        { id: item['id'].to_s, title: Social.excerpt(item['caption']) || kind, url: item['permalink'],
          published_at: item['timestamp'], views: nil,
          likes: Social.int(item['like_count']), comments: Social.int(item['comments_count']) }
      end

      # Insights are missing for some posts; those keep their basic counts.
      def views(http, media_id)
        data = http.get("#{Meta::BASE}/#{media_id}/insights", headers: Meta.headers,
                                                              params: { metric: 'views' })['data']
        row = Array(data).find { |metric| metric['name'] == 'views' }
        value = row&.dig('total_value', 'value') || row&.dig('values', 0, 'value')

        { views: Social.int(value) }
      rescue Error
        {}
      end
    end
  end
end
