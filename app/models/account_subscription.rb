# frozen_string_literal: true

# == Schema Information
#
# Table name: account_subscriptions
#
#  id                     :bigint           not null, primary key
#  access_state           :string           not null
#  cancel_at_period_end   :boolean          default(FALSE), not null
#  current_period_end     :datetime
#  current_period_start   :datetime
#  ended_at               :datetime
#  last_stripe_event_at   :datetime
#  past_due_since         :datetime
#  quantity               :integer          default(1), not null
#  status                 :string
#  stripe_status          :string
#  synced_at              :datetime
#  trial_end              :datetime
#  trial_used_at          :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  stripe_customer_id     :string
#  stripe_item_id         :string
#  stripe_price_id        :string
#  stripe_product_id      :string
#  stripe_subscription_id :string
#
# Indexes
#
#  index_account_subscriptions_on_account_id              (account_id) UNIQUE
#  index_account_subscriptions_on_stripe_customer_id      (stripe_customer_id) UNIQUE WHERE (stripe_customer_id IS NOT NULL)
#  index_account_subscriptions_on_stripe_subscription_id  (stripe_subscription_id) UNIQUE WHERE (stripe_subscription_id IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
# Session 6 fills the Stripe columns and drives access_state from webhooks.
class AccountSubscription < ApplicationRecord
  belongs_to :account

  validates :access_state, inclusion: { in: Plans::ACCESS_STATES }
  validates :quantity, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  # Is this row one an account actually pays through? Internal and operator
  # accounts never bill (Plans::INTERNAL), and a linked child is paid for by
  # its parent — so a row carrying Stripe ids on a non-customer billing
  # account is a mistake, not an instruction. The webhook processor and the
  # nightly sweep both refuse to apply or cancel anything for such a row, and
  # they have to ask the question exactly the same way.
  def billing_customer?
    Plans.billing_account(account).customer?
  end
end
