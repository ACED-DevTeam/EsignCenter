# frozen_string_literal: true

# == Schema Information
#
# Table name: verified_documents
#
#  id            :bigint           not null, primary key
#  kind          :string           not null
#  sha256        :string           not null
#  signed_at     :datetime         not null
#  signers_count :integer          not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint
#  submission_id :bigint
#
# Indexes
#
#  index_verified_documents_on_sha256  (sha256) UNIQUE
#
# This record survives account and submission purge FOREVER (D43): no
# associations, no `dependent`, no foreign keys, and account_id/submission_id
# are plain provenance numbers that may point at rows long gone. Session 7's
# deletion inventory must list this table as KEEP.
class VerifiedDocument < ApplicationRecord
  KINDS = %w[document combined audit_trail].freeze

  validates :sha256, presence: true
  validates :kind, inclusion: { in: KINDS }
end
