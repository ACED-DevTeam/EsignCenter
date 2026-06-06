# frozen_string_literal: true

module AccountConfigs
  REMINDER_DURATIONS = {
    'one_hour' => '1 hour',
    'two_hours' => '2 hours',
    'four_hours' => '4 hours',
    'eight_hours' => '8 hours',
    'twelve_hours' => '12 hours',
    'twenty_four_hours' => '24 hours',
    'two_days' => '2 days',
    'three_days' => '3 days',
    'four_days' => '4 days',
    'five_days' => '5 days',
    'six_days' => '6 days',
    'seven_days' => '7 days',
    'eight_days' => '8 days',
    'fifteen_days' => '15 days',
    'twenty_one_days' => '21 days',
    'thirty_days' => '30 days'
  }.freeze

  DURATION_UNITS = %w[minute minutes hour hours day days].freeze

  module_function

  # Maps a REMINDER_DURATIONS key (e.g. 'two_days') to an ActiveSupport::Duration (2.days), or nil.
  def reminder_duration(key)
    human = REMINDER_DURATIONS[key.to_s]

    return if human.blank?

    number, unit = human.split

    return unless unit.in?(DURATION_UNITS)

    number.to_i.public_send(unit)
  end

  def find_or_initialize_for_key(account, key)
    find_for_account(account, key) ||
      account.account_configs.new(key:, value: AccountConfig::DEFAULT_VALUES[key]&.call)
  end

  def find_for_account(account, key)
    configs = account.account_configs.find_by(key:)

    configs ||= Account.order(:id).first.account_configs.find_by(key:) unless Docuseal.multitenant?

    configs
  end
end
