# frozen_string_literal: true

# == Schema Information
#
# Table name: account_limit_overrides
#
#  id                    :bigint           not null, primary key
#  completions_per_month :integer
#  in_flight             :integer
#  note                  :string
#  seats                 :integer
#  sends_per_month       :integer
#  storage_bytes         :bigint
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :bigint           not null
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
  FIELDS = %w[completions_per_month sends_per_month in_flight seats storage_bytes].freeze

  belongs_to :account

  validates :completions_per_month, :sends_per_month, :in_flight, :seats, :storage_bytes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
end
