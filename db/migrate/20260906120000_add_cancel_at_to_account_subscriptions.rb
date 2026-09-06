# frozen_string_literal: true

# The date Stripe will actually end the subscription on (session 10 walk, W1).
#
# `cancel_at_period_end` is only ONE of the two ways a customer can cancel,
# and it is not the one the Customer Portal uses on a subscription that is
# still in its trial: Stripe leaves that flag false and instead sets
# `cancel_at` to the trial end. The app read the flag alone, so a customer who
# had just cancelled was still told "your free trial ends on the 20th — then
# $20 per month", and nothing keyed on `canceling` (seats, the resume hint)
# ever ran.
#
# So the date itself is written down rather than being inferred from the
# period: it is what the billing card quotes, and NULL means the subscription
# is not set to end at all — which is also how Stripe says "resumed", by
# clearing it.
#
# Safe on existing data and re-runnable: a nullable column with no default is
# a catalogue-only change in Postgres (no table rewrite, no backfill), and
# `if_not_exists` makes a re-run after an interrupted migration a no-op. No
# index: nothing queries on this column — it is read off a row the app has
# already loaded.
class AddCancelAtToAccountSubscriptions < ActiveRecord::Migration[8.1]
  def up
    add_column :account_subscriptions, :cancel_at, :datetime, if_not_exists: true
  end

  def down
    remove_column :account_subscriptions, :cancel_at, if_exists: true
  end
end
