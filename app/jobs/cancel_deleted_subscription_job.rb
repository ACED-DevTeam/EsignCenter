# frozen_string_literal: true

# The retry behind "cancel the subscription the moment they ask to leave".
#
# A deletion must never fail because Stripe is unreachable — the account is
# already frozen and dated, and telling the customer "try again later" when
# they have asked us to delete their account is the wrong answer. So the
# cancel is attempted inline, and a failure becomes this job, which keeps
# trying on ApplicationJob's normal retry policy.
#
# Idempotent: Accounts::Deletion.cancel_subscription! does nothing when the
# row no longer holds a live subscription, and treats "it is already gone" at
# Stripe as success.
class CancelDeletedSubscriptionJob < ApplicationJob
  queue_as :billing

  def perform(account_id)
    account = Account.find_by(id: account_id)

    return if account.nil? || !account.pending_deletion?

    Accounts::Deletion.cancel_subscription!(account)
  end
end
