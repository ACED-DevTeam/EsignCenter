# frozen_string_literal: true

# == Schema Information
#
# Table name: marketing_page_counts
#
#  id       :bigint           not null, primary key
#  campaign :string           default(""), not null
#  count    :integer          default(0), not null
#  day      :date             not null
#  device   :string           not null
#  event    :string           not null
#  path     :string           not null
#  source   :string           not null
#
# Indexes
#
#  index_marketing_page_counts_unique  (day,event,path,source,campaign,device) UNIQUE
#
# One counter on the public pages: how many times one kind of thing happened
# on one day, on one page, from one kind of source, on one kind of device.
# Nothing here identifies a visitor (MarketingAdmin::Traffic writes the rows).
class MarketingPageCount < ApplicationRecord
end
