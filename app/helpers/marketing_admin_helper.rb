# frozen_string_literal: true

# How the marketing page at /admin writes numbers, dates and changes, and the
# geometry of its two hand-drawn charts. No chart library: columns are plain
# elements with a height, and the trend line is one small inline SVG.
#
# No CSS class is named in this file, on purpose. The production image builds
# the stylesheet from app/views and app/javascript only (see the Dockerfile),
# so a class that appeared only here would be missing from the shipped CSS.
# The helpers answer with a word (:up, :today) and the views pick the class.
module MarketingAdminHelper
  MKA_SPARK_WIDTH = 240
  MKA_SPARK_HEIGHT = 44
  MKA_SPARK_PAD = 4

  # "—" for a number an app does not share; never a made-up zero.
  def mka_number(value)
    value.nil? ? '—' : number_with_delimiter(value)
  end

  def mka_signed(value)
    return 'No change' if value.zero?

    "#{value.positive? ? '+' : '−'}#{number_with_delimiter(value.abs)}"
  end

  # "Nov 21", and "Nov 21, 2025" once it is not this year: a card can be
  # showing numbers from long ago, and then the year is the point.
  def mka_day(day)
    day.strftime(day.year == MarketingAdmin.today.year ? '%b %-d' : '%b %-d, %Y')
  end

  def mka_weekday(day)
    day.strftime('%a, %b %-d')
  end

  def mka_time(time)
    time.in_time_zone(MarketingAdmin::TIME_ZONE).strftime('%b %-d, %-l:%M %P')
  end

  def mka_count(value, noun)
    "#{mka_number(value)} #{value == 1 ? noun : noun.pluralize}"
  end

  # This week against the week before, in words. Returns [sentence, direction].
  def mka_trend(now, before)
    return ['Same as the 7 days before', :flat] if now == before
    return ['Up from none in the 7 days before', :up] if before.zero?

    change = ((now - before) * 100.0 / before).round
    change = now > before ? 1 : -1 if change.zero?

    ["#{change.positive? ? 'Up' : 'Down'} #{change.abs}% on the 7 days before", change.positive? ? :up : :down]
  end

  # Column heights as percentages of the tallest day. A day with anything on
  # it stays visible however tall the busiest day was.
  def mka_column_heights(values)
    peak = values.compact.max.to_i

    values.map do |value|
      next 0 if value.to_i.zero? || peak.zero?

      [(value * 100.0 / peak).round(1), 3].max
    end
  end

  # Which kind of column a day is: today stands out, a day with nothing is a
  # faint tick, and a day before counting began is a gap, because "not
  # counted" is not zero.
  def mka_column_kind(day, today)
    return :gap unless day.fetch(:counted, true)
    return :empty if day[:value].zero?

    day[:day] == today ? :today : :day
  end

  def mka_direction(value)
    return :flat if value.zero?

    value.positive? ? :up : :down
  end

  # Points for the followers trend line: [[x, y], ...] in the SVG's own
  # units, spaced by date so a missed day leaves a gap in time, not a kink.
  def mka_spark_points(rows)
    first = rows.first.day
    span = [(rows.last.day - first).to_i, 1].max
    low, high = rows.map(&:followers).minmax
    if low == high
      low -= 1
      high += 1
    end
    inner_width = MKA_SPARK_WIDTH - (MKA_SPARK_PAD * 2)
    inner_height = MKA_SPARK_HEIGHT - (MKA_SPARK_PAD * 2)

    rows.map do |row|
      [(MKA_SPARK_PAD + ((row.day - first).to_f / span * inner_width)).round(1),
       (MKA_SPARK_PAD + ((1 - ((row.followers - low).to_f / (high - low))) * inner_height)).round(1)]
    end
  end
end
