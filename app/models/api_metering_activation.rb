# frozen_string_literal: true

# A deployment timestamp, not a process-start timestamp: restarting Rails must
# never move the metering boundary and forgive the current month's usage. The
# migration seeds this singleton; schema-loaded fresh databases initialize it
# before their first API creation. An explicit ISO8601 setting supports a
# coordinated future rollout without charging pre-rollout documents.
class ApiMeteringActivation < ApplicationRecord
  KEY = 'api_usage_tiers'

  validates :key, :starts_at, presence: true

  def self.starts_at
    configured = ENV['API_METERING_STARTS_AT'].presence

    return Time.iso8601(configured) if configured

    row = find_by(key: KEY) || create_or_find_by!(key: KEY) { |record| record.starts_at = Time.current }

    row.starts_at
  end
end
