# frozen_string_literal: true

# Instance-global settings live as AccountConfig rows on the platform-operator
# account. This module is the ONE place those rows are read or written, and
# every read is scoped to that account — never to the lowest-id account.
module OperatorConfigs
  class MissingOperatorAccountError < StandardError; end

  module_function

  # The real operator account only. Test mode clones the operator account
  # into a testing child that carries the same account_kind, so the kind
  # alone is ambiguous: the child is excluded by its testing link.
  def candidates
    Account.where(account_kind: Account::OPERATOR_KIND)
           .where.not(id: AccountLinkedAccount.testing.select(:linked_account_id))
  end

  def account
    candidates.take
  end

  def fetch(key)
    operator_account = account

    return if operator_account.nil?

    operator_account.account_configs.find_by(key:)&.value
  end

  def enabled?(key)
    fetch(key) == true
  end

  def set!(key, value)
    operator_account = account

    raise MissingOperatorAccountError, 'No operator account exists; run `rake operator:seed`' if operator_account.nil?

    operator_account.account_configs.find_or_initialize_by(key:).tap do |config|
      config.update!(value:)
    end
  end
end
