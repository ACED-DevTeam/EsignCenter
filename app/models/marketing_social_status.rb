# frozen_string_literal: true

# == Schema Information
#
# Table name: marketing_social_statuses
#
#  id              :bigint           not null, primary key
#  error           :string
#  last_attempt_at :datetime
#  last_success_at :datetime
#  platform        :string           not null
#  state           :string           not null
#  triggered_by    :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_marketing_social_statuses_on_platform  (platform) UNIQUE
#
# The outcome of the latest check of one social app (MarketingAdmin::Social).
class MarketingSocialStatus < ApplicationRecord
  STATES = [OK = 'ok', ERROR = 'error'].freeze

  validates :state, inclusion: { in: STATES }
end
