# frozen_string_literal: true

# One account's purge, on its own, so a single account that cannot be emptied
# never stops the rest of the night's work (Accounts::Retention.purge_due!
# enqueues one of these per account).
#
# A REFUSAL is not retried: "this account still holds a live subscription" or
# "this is an internal account" will be just as true in six seconds, and the
# operator has already been told. Anything else — a broken file, a database
# hiccup — retries through ApplicationJob's normal policy.
class AccountPurgeJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    account = Account.find_by(id: account_id)

    return if account.nil?

    Accounts::Purge.call(account)
  rescue Accounts::Purge::Refused => e
    ErrorReport.warning(e.message, account_id:)

    nil
  end
end
