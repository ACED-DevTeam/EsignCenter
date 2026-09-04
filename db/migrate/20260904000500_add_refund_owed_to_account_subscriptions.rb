# frozen_string_literal: true

# The one thing the app knew about an unpaid duplicate refund and then forgot.
#
# When the app cancels a duplicate subscription it owes the money back, and
# when it decides a PERSON must send that money (more separate payments than
# it returns unattended, an invoice naming no payment) the account's row moves
# on to the live subscription the customer is actually paying for — it must,
# or a paying customer sits on the free plan. But once the row names another
# subscription, nothing ever looks at the dead one again: a dead subscription
# raises no more webhooks, and the nightly sweep only re-checks the
# subscription the row still names. The debt lived only in a Stripe metadata
# stamp and in an alert somebody read once.
#
# This column is the row's own memory of it: the id of the subscription whose
# refund is still owed. The nightly sweep retries the settlement from it, so
# the moment the reason it could not be paid automatically goes away (an
# operator refunds part of it by hand, a payment list becomes readable) the
# rest is settled and the column is cleared. Review 6 N2.
class AddRefundOwedToAccountSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :account_subscriptions, :refund_owed_subscription_id, :string
  end
end
