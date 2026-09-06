# frozen_string_literal: true

# One person's agreement to one legal document, at one moment (Session 9
# phase A). Written by LegalDocuments.record_acceptance! at every door that
# creates a login and never touched again: agreeing to a newer version is a
# new row, so the table reads as a history rather than a current state.
#
# The row is only worth having if the words behind it can still be produced,
# which is what `version` and `sha256` are for — see docs/legal.md.
#
# The row FOLLOWS the person. `account_id` starts as the account they were in
# when they accepted and is rewritten if they later move to another team
# (Accounts::MoveUser::MOVED_TABLES), because the alternative is leaving the
# only record of what somebody agreed to inside an account that is about to be
# archived and purged. Read it as "whose account holds this row today", never
# as "which company they were in when they clicked".
# == Schema Information
#
# Table name: legal_acceptances
#
#  id          :bigint           not null, primary key
#  accepted_at :datetime         not null
#  document    :string           not null
#  ip          :string
#  sha256      :string           not null
#  source      :string           not null
#  user_agent  :string
#  version     :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#  user_id     :bigint           not null
#
# Indexes
#
#  index_legal_acceptances_on_account_id            (account_id)
#  index_legal_acceptances_on_user_id               (user_id)
#  index_legal_acceptances_on_user_id_and_document  (user_id,document)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
class LegalAcceptance < ApplicationRecord
  # The doors that can create a login. A source that is not one of these is a
  # programming error rather than a refusal (typo protection).
  SIGNUP_EMAIL = 'signup_email'
  SIGNUP_GOOGLE = 'signup_google'
  SIGNUP_APPLE = 'signup_apple'
  INVITE = 'invite'

  SOURCES = [SIGNUP_EMAIL, SIGNUP_GOOGLE, SIGNUP_APPLE, INVITE].freeze

  belongs_to :user
  belongs_to :account

  validates :document, :version, :sha256, :accepted_at, presence: true
  validates :source, inclusion: { in: SOURCES }
end
