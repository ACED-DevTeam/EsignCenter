# frozen_string_literal: true

module MarketingAdmin
  # The "Channels" section of /admin: followers, views and posts on each
  # social app.
  #
  # YouTube, Facebook and Instagram are read from their own APIs once a day
  # (MarketingSocialSnapshotJob) and on "Refresh now". TikTok has no API we
  # may use, so its numbers are typed in on the page from TikTok Studio.
  #
  # Three rules the page depends on:
  #
  #   * an app with no credentials is "not connected", never an error;
  #   * each app is checked on its own — one failing marks only its own card
  #     and keeps its last good numbers, dated;
  #   * one snapshot per app per America/Chicago day; a later check that day
  #     replaces it, so history is one row a day.
  #
  # Credentials come from the environment only and never reach the database,
  # the log or the page: Http scrubs every error message before it is stored.
  module Social
    class Error < StandardError
      attr_reader :status

      def initialize(message = nil, status: nil)
        super(message)

        @status = status
      end
    end

    # `views_total` says what the views number IS. YouTube's is the channel's
    # running total and TikTok's is the total typed in from TikTok Studio:
    # both only ever grow, so their change over a week means something. The
    # two Meta apps share no channel total — theirs is added up from the
    # newest posts we are allowed to read, so it moves when an old post drops
    # off the end of that list as well as when somebody watches one. That
    # number is labelled as recent posts and its change is never shown.
    PLATFORMS = {
      'youtube' => { name: 'YouTube', unit: 'subscriber', posts: 'Videos', views: 'Views', views_total: true,
                     needs: 'Waiting for a YouTube channel ID and API key.' },
      'facebook' => { name: 'Facebook', unit: 'follower', posts: 'Reels', views: 'Plays, recent reels',
                      views_total: false,
                      views_note: "Added up from the newest #{Facebook::MAX_POSTS} reels, not a running total.",
                      needs: 'Waiting for the Facebook Page ID and the Meta Page token.' },
      'instagram' => { name: 'Instagram', unit: 'follower', posts: 'Posts', views: 'Views, recent posts',
                       views_total: false,
                       views_note: "Added up from the newest #{Instagram::INSIGHT_POSTS} posts, not a running total.",
                       needs: 'Waiting for the Instagram account ID. The Meta Page token covers it too.' },
      'tiktok' => { name: 'TikTok', unit: 'follower', posts: 'Videos', views: 'Views', views_total: true,
                    needs: 'TikTok has no connection to set up. Type in its numbers from TikTok Studio once a week.' }
    }.freeze

    ADAPTERS = { 'youtube' => Youtube, 'facebook' => Facebook, 'instagram' => Instagram }.freeze

    MANUAL = 'manual'
    API = 'api'
    TRIGGERS = [CRON = 'cron', MANUAL_REFRESH = 'manual', ENTRY = 'entry'].freeze

    REFRESH_COOLDOWN = 10.minutes
    REFRESH_KEY = 'marketing-social-refresh'
    SERIES_DAYS = 30
    HISTORY_DAYS = 60
    STORED_POSTS = 10
    TOP_POSTS = 8
    # TikTok is typed in weekly; past this the card asks for fresh numbers.
    TIKTOK_STALE_AFTER_DAYS = 8
    # What can be typed in for TikTok, with the largest number each field
    # takes. Three of the columns are 64-bit and are capped far below that, at
    # a number no account will reach; the video count is a 32-bit column and
    # its cap is exactly what the column holds.
    ENTRY_FIELDS = {
      followers: ['Followers', 100_000_000_000],
      total_views: ['Total views', 1_000_000_000_000_000],
      total_likes: ['Total likes', 1_000_000_000_000_000],
      post_count: ['Videos', 2_147_483_647]
    }.freeze

    module_function

    # ---- small helpers the adapters share ---------------------------------

    # A credential slot still carrying its PASTE_ marker is not a credential
    # (the same rule sign-up applies to the Google and Apple keys).
    def env(name)
      value = ENV.fetch(name, '').strip

      value unless value.start_with?(Registrations::PLACEHOLDER_PREFIX)
    end

    def int(value)
      return if value.nil? || value == ''

      Integer(value, exception: false) || Float(value, exception: false)&.round
    end

    # nil when no post shares the number at all: "unknown" is not zero.
    def sum(posts, key)
      values = posts.filter_map { |post| post[key] }

      values.sum if values.any?
    end

    def excerpt(text, max = 120)
      text = text.to_s.squish

      text.truncate(max, omission: '…').presence
    end

    def connected?(platform)
      ADAPTERS.fetch(platform).connected?
    end

    def any_connected?
      ADAPTERS.keys.any? { |platform| connected?(platform) }
    end

    # ---- checking ----------------------------------------------------------

    # Every connected app, each on its own. Never raises: a failure is
    # written to that app's status row and the next app is still checked.
    def run!(trigger: CRON, now: Time.current)
      ADAPTERS.keys.index_with { |platform| check!(platform, trigger:, now:) }
    end

    def check!(platform, trigger:, now: Time.current)
      return :not_connected unless connected?(platform)

      store!(platform, ADAPTERS.fetch(platform).fetch, collected_by: API, now:)
      mark!(platform, MarketingSocialStatus::OK, trigger:, now:)

      :ok
    rescue StandardError => e
      # Error messages are already scrubbed by Http; anything else is a bug
      # in this code, and its message is not shown on the page.
      message = e.is_a?(Error) ? e.message : 'Something went wrong on our side while checking.'

      ErrorReport.error(e, platform:) unless e.is_a?(Error)
      Rails.logger.warn("Marketing social check failed for #{platform}: #{message}")
      mark!(platform, MarketingSocialStatus::ERROR, trigger:, now:, error: message)

      :error
    end

    def store!(platform, numbers, collected_by:, now:)
      posts = Array(numbers[:posts]).sort_by { |post| [-(post[:views] || -1), -(post[:likes] || -1)] }
                                    .first(STORED_POSTS)

      MarketingSocialSnapshot.upsert(
        { platform:, day: MarketingAdmin.today(now), collected_by:, fetched_at: now, posts:,
          **numbers.slice(:account_name, :followers, :total_views, :total_likes, :post_count) },
        unique_by: %i[platform day]
      )
    end

    def mark!(platform, state, trigger:, now:, error: nil)
      status = MarketingSocialStatus.find_or_initialize_by(platform:)
      status.assign_attributes(state:, error:, triggered_by: trigger, last_attempt_at: now)
      status.last_success_at = now if state == MarketingSocialStatus::OK
      status.save!
    end

    # TikTok's weekly entry. Followers is the one number that must be there.
    def record_tiktok!(params, now: Time.current)
      numbers = ENTRY_FIELDS.to_h { |key, (label, limit)| [key, entry(params[key], label, limit)] }

      raise Error, 'Type in the follower count as a whole number.' if numbers[:followers].nil?

      store!('tiktok', numbers.merge(posts: []), collected_by: MANUAL, now:)
      mark!('tiktok', MarketingSocialStatus::OK, trigger: ENTRY, now:)
    end

    # "12,480" and "12 480" are how people type numbers. A number too big for
    # its column is refused here, in words, rather than by the database.
    def entry(raw, label, limit)
      text = raw.to_s.delete(', _').strip

      return if text.blank?

      number = Integer(text, 10, exception: false) if text.match?(/\A\d{1,30}\z/)

      raise Error, 'Use whole numbers only, with no letters.' if number.nil?
      raise Error, "#{label} can be at most #{limit.to_fs(:delimited)}." if number > limit

      number
    end

    # ---- "Refresh now", at most once every ten minutes for everybody -------

    # The same Redis-backed counter every other velocity limit uses: the
    # increment is the claim, so two clicks at the same moment cannot both
    # win. (Like those limits it fails open if Redis is down.)
    def claim_refresh!(now: Time.current)
      RateLimit.call(REFRESH_KEY, limit: 1, ttl: REFRESH_COOLDOWN)
      RateLimit.store.write("#{REFRESH_KEY}-at", now.to_i, expires_in: REFRESH_COOLDOWN)

      true
    rescue RateLimit::LimitApproached
      false
    end

    # Seconds until the button works again; zero when it already does.
    def refresh_available_in(now: Time.current)
      claimed_at = RateLimit.store.read("#{REFRESH_KEY}-at").to_i

      return 0 if claimed_at.zero?

      [claimed_at + REFRESH_COOLDOWN.to_i - now.to_i, 0].max
    end

    # ---- reading -----------------------------------------------------------

    def report(today: MarketingAdmin.today, now: Time.current)
      snapshots = snapshots_by_platform(today)
      started = MarketingSocialSnapshot.group(:platform).minimum(:day)
      statuses = MarketingSocialStatus.all.index_by(&:platform)
      cards = PLATFORMS.keys.map do |platform|
        card(platform, snapshots.fetch(platform, []), statuses[platform], today).tap do |card|
          # The first day there are numbers for at all, not the first in the chart.
          card[:history_starts] = started[platform] if card[:latest]
        end
      end

      {
        cards:,
        any_api_connected: any_connected?,
        last_check_at: statuses.values_at(*ADAPTERS.keys).compact.filter_map(&:last_attempt_at).max,
        refresh_available_in: refresh_available_in(now:),
        top_posts: top_posts(cards)
      }
    end

    # Each app's snapshots for the chart and the week's change — and, whatever
    # its age, its LATEST one. They are fetched apart on purpose: a card shows
    # the last good numbers with their date for as long as there are any, so
    # an app whose checks stopped working months ago still says what it last
    # knew instead of going back to "waiting for its first numbers".
    def snapshots_by_platform(today)
      recent = MarketingSocialSnapshot.where(day: (today - HISTORY_DAYS)..today).order(:day).group_by(&:platform)
      latest = MarketingSocialSnapshot.where(day: ..today).select('DISTINCT ON (platform) *')
                                      .order(:platform, day: :desc).index_by(&:platform)

      latest.to_h { |platform, snapshot| [platform, recent[platform].presence || [snapshot]] }
    end

    # One app's card. `state` is what the page switches on:
    #   not_connected  no credentials (TikTok: nothing typed in yet)
    #   waiting        connected, but no numbers have arrived yet
    #   error          the latest check failed and there is nothing to show
    #   ok             numbers to show (with `problem` when the latest check failed)
    def card(platform, rows, status, today)
      manual = !ADAPTERS.key?(platform)
      failed = status&.state == MarketingSocialStatus::ERROR
      base = { platform:, **PLATFORMS.fetch(platform), manual: }

      # An app that is not connected shows none of what was stored for it.
      return base.merge(blank_card) unless manual ? rows.any? : connected?(platform)

      base.merge(state: card_state(rows.last, failed), problem: (status.error if failed), latest: rows.last,
                 **movement(platform, rows, today), **freshness(rows.last, manual, today))
    end

    def blank_card
      { state: :not_connected, problem: nil, latest: nil, stale: false, entry_due: false, change: nil,
        views_change: nil, history_starts: nil, series: [] }
    end

    def movement(platform, rows, today)
      running_total = PLATFORMS.fetch(platform).fetch(:views_total)

      { change: change_over(rows, 7, :followers),
        views_change: (change_over(rows, 7, :total_views) if running_total),
        history_starts: rows.first&.day,
        series: rows.select { |row| row.day > today - SERIES_DAYS && row.followers } }
    end

    def freshness(latest, manual, today)
      { stale: latest.present? && latest.day != today,
        entry_due: manual && latest.present? && latest.day <= today - TIKTOK_STALE_AFTER_DAYS }
    end

    def card_state(latest, failed)
      return :ok if latest

      failed ? :error : :waiting
    end

    # The change between the latest snapshot and the one `days` earlier.
    #
    # There is not always a snapshot exactly `days` earlier: the history may
    # be shorter than that, a morning's check may have failed, and TikTok is
    # typed in a week or two apart. The comparison then uses the nearest
    # snapshot at least that old (or the oldest one there is), and `exact`
    # says whether it really is `days` days back — so the card can read
    # "since Nov 7" instead of claiming a change "in 7 days" that was measured
    # over fourteen.
    #
    # And there is only a change to show when the snapshot the card is
    # DISPLAYING has that number. If today's check came back without views,
    # the card shows a dash (or likes) for views — a change worked out from two
    # older snapshots would sit next to a number it has nothing to do with.
    def change_over(rows, days, key)
      latest = rows.last

      return if latest.nil? || latest[key].nil?

      known = rows.select { |row| row[key] }

      return if known.size < 2

      base = known.rfind { |row| row.day <= latest.day - days } || known.first

      { value: latest[key] - base[key], since: base.day, exact: base.day == latest.day - days }
    end

    def top_posts(cards)
      posts = cards.select { |card| card[:latest] }.flat_map do |card|
        card[:latest].posts.map { |post| post.symbolize_keys.merge(platform: card[:name]) }
      end

      posts.sort_by { |post| [-(post[:views] || -1), -(post[:likes] || -1)] }.first(TOP_POSTS)
    end
  end
end
