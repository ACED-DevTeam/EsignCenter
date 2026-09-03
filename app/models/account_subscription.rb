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

  # Is this row one that the account it belongs to actually pays through?
  # Two things have to be true, and asking only the second one is a bug we
  # have already had: the account must BE its own billing account
  # (Plans.billing_account), and that account must be a customer.
  #
  # A linked child is paid for by its parent, so the parent's row is the one
  # the app reads for the plan and prints on the billing page; a child's own
  # row is read by nothing. Asking "is my BILLING account a customer?" said
  # yes for such a row — the parent is a customer — and the webhook processor
  # and the nightly sweep would then apply, cancel and refund against a row
  # the rest of the app ignores. Internal and operator accounts never bill at
  # all (Plans::INTERNAL). Either way a row carrying Stripe ids here is a
  # mistake, not an instruction, and both callers have to ask the question
  # exactly the same way.
  def billing_customer?
    return true if Plans.billing_account(account) == account && account.customer?

    report_unmanaged_subscription

    false
  end

  private

  # Refusing the row is the safe half; saying nothing about it is not. A
  # refused row that carries Stripe ids means there is a subscription at
  # Stripe that nothing in this app will ever apply, cancel or refund — a
  # card that may still be charged every month with no code watching it. So
  # the refusal is reported the same way the Linker reports a subscription it
  # left alone (StripeBilling::Linker.report_foreign): one warning, to the
  # channel a person actually watches, rather than a per-account email that a
  # Stripe outage would turn into a thousand messages. A refused row with no
  # Stripe ids on it has no money behind it and stays silent.
  def report_unmanaged_subscription
    return if stripe_subscription_id.blank? && stripe_customer_id.blank?

    ErrorReport.warning("unmanaged Stripe subscription #{stripe_subscription_id.presence || '(none)'} on " \
                        "customer #{stripe_customer_id.presence || '(none)'} left alone: account #{account_id} " \
                        'does not bill for itself, so nothing applies, cancels or refunds it',
                        account_id:)
  end
end
