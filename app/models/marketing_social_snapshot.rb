# frozen_string_literal: true

# == Schema Information
#
# Table name: marketing_social_snapshots
#
#  id           :bigint           not null, primary key
#  account_name :string
#  collected_by :string           not null
#  day          :date             not null
#  fetched_at   :datetime         not null
#  followers    :bigint
#  platform     :string           not null
#  post_count   :integer
#  posts        :text
#  total_likes  :bigint
#  total_views  :bigint
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_marketing_social_snapshots_on_platform_and_day  (platform,day) UNIQUE
#
# What one social app reported on one America/Chicago day
# (MarketingAdmin::Social). `posts` is that day's most-viewed posts.
class MarketingSocialSnapshot < ApplicationRecord
  serialize :posts, coder: JSON

  def posts
    Array(super)
  end
end
