# frozen_string_literal: true

# == Schema Information
#
# Table name: account_limit_overrides
#
#  id                     :bigint           not null, primary key
#  completions_per_month  :integer
#  fair_use_per_seat      :integer
#  in_flight              :integer
#  in_flight_per_seat     :integer
#  note                   :string
#  seats                  :integer
#  sends_per_day_per_seat :integer
#  sends_per_month        :integer
#  storage_bytes          :bigint
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#
# Indexes
#
#  index_account_limit_overrides_on_account_id  (account_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
# Operator-owned per-account limit overrides: a present column wins over the
# plan default in Quotas.limits_for; a nil column leaves the default alone.
# Written by `rake operator:limits` today and by the Session 8 console later;
# no HTTP path writes it.
class AccountLimitOverride < ApplicationRecord
  # Every number the operator can move, in the order the console shows them:
  # the five free-plan CAPS first, then the three paid-plan per-seat WARN
  # thresholds (Session 8). A field added here appears on the console form and
  # in `rake operator:limits` with no further wiring; Quotas.limits_for merges
  # the whole list, so a present column always wins over the plan default.
  CAP_FIELDS = %w[completions_per_month sends_per_month in_flight seats storage_bytes].freeze
  PAID_SIGNAL_FIELDS = %w[fair_use_per_seat sends_per_day_per_seat in_flight_per_seat].freeze
  API_FIELDS = %w[api_completions_per_month].freeze
  FIELDS = (CAP_FIELDS + PAID_SIGNAL_FIELDS + API_FIELDS).freeze

  # NULL inherits the plan; -1 explicitly removes the API cap for enterprise
  # terms. Zero remains a real refusal, just like the other override columns.
  validates :api_completions_per_month,
            numericality: { only_integer: true, greater_than_or_equal_to: -1 }, allow_nil: true

  belongs_to :account

  validates(*(CAP_FIELDS + PAID_SIGNAL_FIELDS).map(&:to_sym),
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true)
end
