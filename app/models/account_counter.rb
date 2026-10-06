# frozen_string_literal: true

# == Schema Information
#
# Table name: account_counters
#
#  id         :bigint           not null, primary key
#  key        :string           not null
#  period     :string           default(""), not null
#  value      :bigint           default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint           not null
#
# Indexes
#
#  index_account_counters_on_account_id                     (account_id)
#  index_account_counters_on_account_id_and_key_and_period  (account_id,key,period) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class AccountCounter < ApplicationRecord
  belongs_to :account
end
