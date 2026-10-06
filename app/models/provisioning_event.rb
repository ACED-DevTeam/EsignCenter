# frozen_string_literal: true

# == Schema Information
#
# Table name: provisioning_events
#
#  id              :bigint           not null, primary key
#  email           :string           not null
#  idempotency_key :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  webhook_url_id  :bigint
#
# Indexes
#
#  index_provisioning_events_on_account_id       (account_id)
#  index_provisioning_events_on_idempotency_key  (idempotency_key) UNIQUE WHERE (idempotency_key IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class ProvisioningEvent < ApplicationRecord
  belongs_to :account
end
