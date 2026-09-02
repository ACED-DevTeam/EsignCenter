# frozen_string_literal: true

# == Schema Information
#
# Table name: abuse_flags
#
#  id           :bigint           not null, primary key
#  details      :jsonb            not null
#  kind         :string           not null
#  period       :string           default(""), not null
#  resolved_at  :datetime
#  subject_type :string
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  subject_id   :bigint
#
# Indexes
#
#  index_abuse_flags_on_account_id                      (account_id)
#  index_abuse_flags_on_account_id_and_kind_and_period  (account_id,kind,period) UNIQUE WHERE ((period)::text <> ''::text)
#  index_abuse_flags_on_resolved_at_and_created_at      (resolved_at,created_at)
#  index_abuse_flags_on_subject_type_and_subject_id     (subject_type,subject_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
# A row the operator should look at: a paid account past fair use, an
# abnormal send velocity, a spam complaint, a bounce storm, a reported
# document. Rows with a period are one-per-(account, kind, period); rows with
# an empty period are separate events. Written only through AbuseFlags.record!.
# Session 8's abuse queue reads this table.
class AbuseFlag < ApplicationRecord
  KINDS = %w[fair_use_review send_velocity in_flight complaint bounce_rate document_report].freeze

  belongs_to :account
  belongs_to :subject, polymorphic: true, optional: true

  scope :open, -> { where(resolved_at: nil) }

  validates :kind, presence: true

  # ApplicationRecord's strip_attributes turns a blank period into nil, but a
  # period-less flag (document_report) is stored as '' by contract: the
  # column is NOT NULL and the unique index applies only where period <> ''.
  before_validation { self.period = '' if period.nil? }
end
