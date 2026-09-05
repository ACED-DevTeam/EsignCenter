# frozen_string_literal: true

# When a complimentary paid plan runs out (Session 8).
#
# The operator can put an account on the paid plan by hand — a pilot, a
# migration, an apology. That has always been possible (`rake plans:grant`)
# and it has always been permanent, which is how a "two-week trial for the
# law firm" is still running eight months later with nobody able to say why.
#
# A comp now always carries the date it ends: the console refuses a grant with
# no expiry, and CompExpiryJob revokes the plan on the hour after it passes,
# down the same path as a hand-revoke (D43 prospective counters included).
# NULL means "not a comp" — a Stripe-backed subscription never has one.
class AddCompExpiresAtToAccountSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :account_subscriptions, :comp_expires_at, :datetime

    add_index :account_subscriptions, :comp_expires_at, where: 'comp_expires_at IS NOT NULL'
  end
end
