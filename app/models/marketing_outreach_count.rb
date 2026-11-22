# frozen_string_literal: true

# == Schema Information
#
# Table name: marketing_outreach_counts
#
#  id         :bigint           not null, primary key
#  count      :integer          default(0), not null
#  day        :date             not null
#  kind       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_marketing_outreach_counts_on_day_and_kind  (day,kind) UNIQUE
#
# One outreach total for one day, reported by the Mac automations
# (MarketingAdmin::Outreach).
class MarketingOutreachCount < ApplicationRecord
end
