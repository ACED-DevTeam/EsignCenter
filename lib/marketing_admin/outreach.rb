# frozen_string_literal: true

module MarketingAdmin
  # The "Outreach" section of /admin: how much the Mac automations did each
  # day. They report totals to POST /api/marketing/outreach with a shared
  # token (docs/marketing-admin.md); this app only stores and shows them.
  module Outreach
    KINDS = {
      'emails_sent' => 'Emails sent',
      'replies' => 'Replies',
      'reddit_comments' => 'Reddit comments',
      'facebook_group_comments' => 'Facebook group comments'
    }.freeze

    # Column headings narrow enough for all four to fit on a phone.
    SHORT_LABELS = {
      'emails_sent' => 'Emails', 'replies' => 'Replies', 'reddit_comments' => 'Reddit',
      'facebook_group_comments' => 'Groups'
    }.freeze

    TOKEN_ENV = 'MARKETING_OUTREACH_TOKEN'
    # Short enough to guess is the same as no token at all.
    MINIMUM_TOKEN_LENGTH = 24
    # "set" replaces the day's number and is safe to send twice; "add" is for
    # a job that reports each thing as it happens.
    MODES = %w[set add].freeze
    MAX_COUNT = 1_000_000
    TABLE_DAYS = 14
    # A job that has been down for a while may catch up, but not rewrite history.
    MAX_DAYS_BACK = 60

    DAY_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

    Invalid = Class.new(StandardError)

    module_function

    def token
      value = ENV.fetch(TOKEN_ENV, '').strip

      value if value.length >= MINIMUM_TOKEN_LENGTH && !value.start_with?(Registrations::PLACEHOLDER_PREFIX)
    end

    def configured?
      token.present?
    end

    def authorized?(given)
      return false unless configured? && given.present?

      ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(given.to_s),
                                                  Digest::SHA256.hexdigest(token))
    end

    # payload: { "day" => "2026-11-21", "mode" => "set", "emails_sent" => 12, ... }
    # Kinds that are left out are left alone. Raises Invalid with a sentence
    # the job's log can show.
    def record!(payload, today: MarketingAdmin.today)
      day = parse_day(payload['day'], today)
      mode = payload.fetch('mode', 'set')
      counts = parse_counts(payload)

      raise Invalid, "mode must be one of: #{MODES.join(', ')}" unless MODES.include?(mode)
      raise Invalid, "send at least one of: #{KINDS.keys.join(', ')}" if counts.empty?

      MarketingOutreachCount.upsert_all(
        counts.map { |kind, count| { day:, kind:, count: } },
        unique_by: %i[day kind],
        on_duplicate: Arel.sql(on_duplicate_sql(mode))
      )

      { day: day.iso8601, mode:, counts: stored(day) }
    end

    def on_duplicate_sql(mode)
      value = mode == 'add' ? 'marketing_outreach_counts.count + EXCLUDED.count' : 'EXCLUDED.count'

      "count = #{value}, updated_at = CURRENT_TIMESTAMP"
    end

    def stored(day)
      found = MarketingOutreachCount.where(day:).pluck(:kind, :count).to_h

      KINDS.keys.index_with { |kind| found.fetch(kind, 0) }
    end

    # "Today" is today in Chicago, the clock the page counts by: a report for
    # a day that has not started there yet is refused, not filed early.
    def parse_day(raw, today)
      return today if raw.nil? || raw == ''

      raise Invalid, 'day must look like 2026-11-21' unless raw.is_a?(String) && raw.match?(DAY_FORMAT)

      day = Date.iso8601(raw)

      raise Invalid, 'day cannot be after today (Central time)' if day > today
      raise Invalid, "day cannot be more than #{MAX_DAYS_BACK} days ago" if day < today - MAX_DAYS_BACK

      day
    rescue Date::Error
      raise Invalid, 'day must look like 2026-11-21'
    end

    def parse_counts(payload)
      KINDS.keys.filter_map do |kind|
        next unless payload.key?(kind)

        count = whole_number(payload[kind])

        raise Invalid, "#{kind} must be a whole number from 0 to #{MAX_COUNT}" unless count&.between?(0, MAX_COUNT)

        [kind, count]
      end
    end

    # 12, "12" and 12.0 are whole numbers. 12.5 is not, and is refused rather
    # than quietly stored as 12; so is anything that is not a number at all.
    def whole_number(value)
      case value
      when Integer then value
      when Float then value.to_i if value.finite? && value == value.floor
      when String then value.to_i if value.match?(/\A\d{1,9}\z/)
      end
    end

    def report(today: MarketingAdmin.today)
      days = ((today - 29)..today).to_a
      counts = MarketingOutreachCount.where(day: days.first..today).pluck(:day, :kind, :count)
                                     .to_h { |day, kind, count| [[day, kind], count] }
      on = ->(kind, list) { list.sum { |day| counts.fetch([day, kind], 0) } }

      {
        any: counts.any?,
        last_reported_at: MarketingOutreachCount.maximum(:updated_at),
        kinds: KINDS.map do |kind, label|
          { key: kind, label:, short: SHORT_LABELS.fetch(kind), last7: on.call(kind, days.last(7)),
            previous7: on.call(kind, days.last(14).first(7)), last30: on.call(kind, days) }
        end,
        days: days.last(TABLE_DAYS).reverse.map do |day|
          { day:, reported: KINDS.keys.any? { |kind| counts.key?([day, kind]) },
            counts: KINDS.keys.index_with { |kind| counts[[day, kind]] } }
        end
      }
    end
  end
end
