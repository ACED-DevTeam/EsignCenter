# frozen_string_literal: true

# One line per change the operator console made: who, to which account, what,
# why, and from where. Written only through OperatorEvents.record!, always
# inside the transaction that makes the change, so there is no state in this
# application an operator can move without leaving this row behind.
#
# `operator` is optional because the console is not the only thing that
# applies an operator's decision: a comp expires on the clock
# (CompExpiryJob), and that row names no human. Everything else does.
# == Schema Information
#
# Table name: operator_events
#
#  id               :bigint           not null, primary key
#  action           :string           not null
#  details          :jsonb            not null
#  ip               :string
#  reason           :text
#  subject_type     :string
#  created_at       :datetime         not null
#  account_id       :bigint
#  operator_user_id :bigint
#  subject_id       :bigint
#
# Indexes
#
#  index_operator_events_on_account_id                       (account_id)
#  index_operator_events_on_account_id_and_created_at        (account_id,created_at)
#  index_operator_events_on_action                           (action)
#  index_operator_events_on_operator_user_id                 (operator_user_id)
#  index_operator_events_on_operator_user_id_and_created_at  (operator_user_id,created_at)
#  index_operator_events_on_subject_type_and_subject_id      (subject_type,subject_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (operator_user_id => users.id) ON DELETE => nullify
#
class OperatorEvent < ApplicationRecord
  # The console's whole vocabulary, spelled out so a typo in a controller is
  # a failing validation rather than a row nobody can search for. Dotted
  # names: the subject first, then what happened to it.
  ACTIONS = %w[
    account.suspend account.lift_suspension
    sending.resume
    deletion.cancel
    purge.run purge.release_claim
    limits.update
    comp.grant comp.revoke comp.expire
    abuse.resolve
    stripe.retry_event stripe.adopt
    scheduler.run_now
    settings.update
    impersonation.start impersonation.end impersonation.refused impersonation.action
  ].freeze

  belongs_to :operator, class_name: 'User', foreign_key: :operator_user_id,
                        optional: true, inverse_of: false
  belongs_to :account, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  validates :action, presence: true, inclusion: { in: ACTIONS }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # "the system", when nobody pressed the button.
  def operator_label
    operator&.email || I18n.t('operator_event_system_actor')
  end
end
