# frozen_string_literal: true

# Puts the four starter templates into a brand-new customer account (D50).
#
# Enqueued from `Registrations.save_signup`, which is the one place BOTH
# self-serve doors — the email form and the Google button — save through, so
# neither door can forget to ask and no third door has to remember.
#
# Two rules make this safe to hang off a sign-up:
#
#   * it never runs before the account exists — `enqueue_after_transaction_commit`
#     holds the enqueue until the sign-up transaction has committed, so a
#     worker can never look for an account that is not there yet;
#   * it never raises. Seeding a nice-to-have is not worth a retry storm
#     against a person's first minute in the product, and ApplicationRecord's
#     retry policy would repeat the whole attempt five times over. A failure
#     is reported and dropped; the account is a perfectly ordinary empty one,
#     and the first-run checklist still tells them what to do.
class StarterTemplatesJob < ApplicationJob
  queue_as :default

  # The account row is written inside the sign-up transaction; a job enqueued
  # before that commits would find nothing.
  self.enqueue_after_transaction_commit = true

  def perform(account_id)
    account = Account.find_by(id: account_id)

    return if account.nil?

    StarterTemplates.seed!(account)
  rescue StandardError => e
    ErrorReport.error(e, account_id:)
  end
end
