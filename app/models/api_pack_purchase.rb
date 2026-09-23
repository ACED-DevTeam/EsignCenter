# frozen_string_literal: true

# A durable money operation, written BEFORE any invoice is created. A timeout
# or rolled-back sync cannot erase the identifier Stripe charged against.
class ApiPackPurchase < ApplicationRecord
  belongs_to :account_subscription

  validates :operation_key, :stripe_subscription_id, :stripe_customer_id, :expires_at, presence: true
  validates :previous_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :quantity, :added_quantity, numericality: { only_integer: true, greater_than: 0 }

  scope :open, -> { where(applied_at: nil, closed_at: nil) }

  def amount_cents
    added_quantity * StripeBilling::API_PACK_USD * 100
  end
end
