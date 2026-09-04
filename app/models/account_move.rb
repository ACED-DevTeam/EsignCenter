# frozen_string_literal: true

# == Schema Information
#
# Table name: account_moves
#
#  id              :bigint           not null, primary key
#  created_at      :datetime         not null
#  from_account_id :bigint           not null
#  to_account_id   :bigint           not null
#  user_id         :bigint           not null
#
# Indexes
#
#  index_account_moves_on_from_account_id  (from_account_id)
#  index_account_moves_on_to_account_id    (to_account_id)
#  index_account_moves_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (from_account_id => accounts.id)
#  fk_rails_...  (to_account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
# One line per "join this team" (Accounts::MoveUser): who moved, out of which
# account, into which one. Written once and never touched again.
class AccountMove < ApplicationRecord
  belongs_to :from_account, class_name: 'Account'
  belongs_to :to_account, class_name: 'Account'
  belongs_to :user
end
