# frozen_string_literal: true

# A seat purchase Stripe PARKED, remembered instead of thrown away
# (checkpoint 7, review B — B1).
#
# When a card needs a second step (3-D Secure), Stripe answers the seat
# purchase with a `pending_update` rather than applying it: the subscription
# still bills for the old number and nothing has been charged. Until now the
# app simply told the admin "finish it in Manage billing, then invite again"
# and forgot the whole thing — so a customer who DID finish it paid the
# proration, the hourly sweep took the seat straight back off the
# subscription, and no invitation was ever sent.
#
# These two columns are the memory of that parked purchase. The invitation row
# is written immediately, in a `payment_pending` state:
#
#   * `payment_pending_until` — the moment Stripe's own pending update expires
#     (its `expires_at`). Non-NULL is what MAKES a row parked: it occupies no
#     seat, sends no mail, and is not `pending`. If the customer never
#     finishes the card step, the hourly sweep drops the row at this deadline
#     without asking Stripe for anything, because nothing was ever added.
#
#   * `pending_quantity` — the seat count the purchase was for. When a
#     subscription apply later lands with at least that many seats, the seat
#     really was bought, and the parked row is promoted to an ordinary pending
#     invitation: a fresh token, a fresh week, and the invitation email the
#     customer paid for.
#
# Both are NULLABLE and every existing row is left NULL: a NULL pair is
# exactly what an ordinary invitation looks like, so nothing about the rows
# already in the table changes.
class AddPaymentPendingToAccountInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :account_invites, :payment_pending_until, :datetime
    add_column :account_invites, :pending_quantity, :integer

    add_index :account_invites, :payment_pending_until, where: 'payment_pending_until IS NOT NULL'
  end
end
