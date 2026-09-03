# frozen_string_literal: true

# When Stripe says the subscription actually ended. The billing period end is
# not the same thing: a subscription cancelled immediately keeps a period end
# almost a month in the future, and the "your subscription ended on …" banner
# was reading that. Stripe's own `ended_at` (or `canceled_at` when it has not
# been stamped yet) is the honest date.
class AddEndedAtToAccountSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :account_subscriptions, :ended_at, :datetime
  end
end
