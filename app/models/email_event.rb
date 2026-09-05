# frozen_string_literal: true

# == Schema Information
#
# Table name: email_events
#
#  id                 :bigint           not null, primary key
#  data               :text             not null
#  email              :string           not null
#  emailable_type     :string           not null
#  event_datetime     :datetime         not null
#  event_type         :string           not null
#  provider_event_key :string
#  tag                :string           not null
#  created_at         :datetime         not null
#  account_id         :bigint           not null
#  emailable_id       :bigint           not null
#  message_id         :string           not null
#
# Indexes
#
#  index_email_events_on_account_id_and_event_datetime  (account_id,event_datetime)
#  index_email_events_on_email                          (email)
#  index_email_events_on_email_event_types              (email) WHERE ((event_type)::text = ANY (ARRAY[('bounce'::character varying)::text, ('soft_bounce'::character varying)::text, ('permanent_bounce'::character varying)::text, ('complaint'::character varying)::text, ('soft_complaint'::character varying)::text]))
#  index_email_events_on_emailable                      (emailable_type,emailable_id)
#  index_email_events_on_message_id                     (message_id)
#  index_email_events_on_provider_event_key             (provider_event_key) UNIQUE WHERE (provider_event_key IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class EmailEvent < ApplicationRecord
  belongs_to :emailable, polymorphic: true
  belongs_to :account

  attribute :data, :string, default: -> { {} }

  serialize :data, coder: JSON

  before_validation :maybe_set_account, on: :create

  # The account this message belongs to. Every emailable answers it the same
  # way except the one that IS an account: the SaaS lifecycle mail attributes
  # its send rows to the account itself (Session 10, review 8 C3), because
  # there is no submitter and no user behind a letter addressed to whoever
  # administers the account.
  def maybe_set_account
    self.account ||= emailable.is_a?(Account) ? emailable : emailable.account
  end
end
