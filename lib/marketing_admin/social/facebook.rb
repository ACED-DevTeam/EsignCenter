# frozen_string_literal: true

module MarketingAdmin
  module Social
    # The Facebook Page, read through Meta's Graph API with a long-lived Page
    # token (permissions: pages_show_list, pages_read_engagement,
    # read_insights). Up to four requests a check: the Page, its reels
    # (falling back to videos), and one batch request for every reel's plays.
    module Facebook
      PAGE_ENV = 'MARKETING_FACEBOOK_PAGE_ID'
      METRICS = 'total_video_views,fb_reels_total_plays,blue_reels_play_count,' \
                'post_video_likes_by_reaction_type,post_video_social_actions'
      MAX_POSTS = 40
      BUDGET = 4

      module_function

      def connected?
        Social.env(PAGE_ENV).present? && Social.env(Meta::TOKEN_ENV).present?
      end

      def fetch
        http = Meta.http(BUDGET)
        page_id = Social.env(PAGE_ENV)
        page = http.get("#{Meta::BASE}/#{page_id}", headers: Meta.headers,
                                                    params: { fields: 'name,followers_count,fan_count' })
        posts = reels(http, page_id)

        add_insights(http, posts)

        { account_name: page['name'],
          followers: Social.int(page['followers_count']) || Social.int(page['fan_count']),
          total_views: Social.sum(posts, :views), total_likes: Social.sum(posts, :likes),
          post_count: posts.size, posts: }
      end

      def reels(http, page_id)
        params = { fields: 'id,description,title,created_time,permalink_url', limit: MAX_POSTS }
        list = begin
          http.get("#{Meta::BASE}/#{page_id}/video_reels", headers: Meta.headers, params:)
        rescue Error
          http.get("#{Meta::BASE}/#{page_id}/videos", headers: Meta.headers, params:)
        end

        list.fetch('data', []).first(MAX_POSTS).map { |video| post(video) }
      end

      def post(video)
        link = video['permalink_url'].to_s
        link = "https://www.facebook.com#{link}" if link.start_with?('/')

        { id: video['id'].to_s,
          title: Social.excerpt(video['title'] || video['description']) || 'Facebook reel',
          url: link.presence, published_at: video['created_time'],
          views: nil, likes: nil, comments: nil }
      end

      # One batch request for every reel. If it fails the reels are kept
      # without numbers rather than failing the whole app.
      def add_insights(http, posts)
        return if posts.empty?

        batch = posts.map do |post|
          { method: 'GET', relative_url: "#{Meta::VERSION}/#{post[:id]}/video_insights?metric=#{METRICS}" }
        end
        answers = http.post("#{Meta::HOST}/", headers: Meta.headers,
                                              body: { include_headers: 'false', batch: batch.to_json })

        Array(answers).each_with_index do |answer, index|
          next unless answer.is_a?(Hash) && answer['code'] == 200 && posts[index]

          posts[index].merge!(read_insights(JSON.parse(answer['body'].to_s)['data']))
        end
      rescue Error, JSON::ParserError
        nil
      end

      def read_insights(data)
        metric = ->(name) { Array(data).find { |row| row['name'] == name }&.dig('values', 0, 'value') }
        social = metric.call('post_video_social_actions')
        likes = metric.call('post_video_likes_by_reaction_type')

        { views: Social.int(metric.call('fb_reels_total_plays')) || Social.int(metric.call('blue_reels_play_count')) ||
          Social.int(metric.call('total_video_views')),
          likes: likes.is_a?(Hash) ? likes.values.sum(&:to_i) : Social.int(likes),
          comments: social.is_a?(Hash) ? Social.int(social['COMMENT'] || social['comment']) : nil }
      end
    end
  end
end
