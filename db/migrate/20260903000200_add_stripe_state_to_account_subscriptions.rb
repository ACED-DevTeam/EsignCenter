# frozen_string_literal: true

# Stripe becomes the source of truth for a customer account's subscription:
# `stripe_status` is the raw status as last seen, `access_state` stays the
# app's own verdict (Plans::ACCESS_STATES). `trial_used_at` is set the first
# time a subscription with a trial appears and never cleared — one trial per
# account, ever. `past_due_since` is when the dunning clock started.
class AddStripeStateToAccountSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :account_subscriptions, :trial_used_at, :datetime
    add_column :account_subscriptions, :past_due_since, :datetime
    add_column :account_subscriptions, :stripe_status, :string
    add_column :account_subscriptions, :synced_at, :datetime
    add_column :account_subscriptions, :last_stripe_event_at, :datetime
  end
end
