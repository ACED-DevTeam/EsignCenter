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
           .where.not(id: Account.testing_child_ids)
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

  # Unsetting a key REMOVES the row rather than blanking it: the value column
  # is NOT NULL and ApplicationRecord turns a blank string into nil on its way
  # in, so "no value" has exactly one representation — no row.
  #
  # No operator account is refused here exactly as it is in `set!` (review 1,
  # B-L5). It used to answer quietly, so clearing the alert address on a
  # deployment that had never been seeded said "Settings saved" having done
  # nothing at all — and left an audit row claiming the change. The caller
  # turns this into the "run `rake operator:seed`" sentence.
  def clear!(key)
    operator_account = account

    raise MissingOperatorAccountError, 'No operator account exists; run `rake operator:seed`' if operator_account.nil?

    operator_account.account_configs.find_by(key:)&.destroy!
  end

  def set!(key, value)
    operator_account = account

    raise MissingOperatorAccountError, 'No operator account exists; run `rake operator:seed`' if operator_account.nil?

    operator_account.account_configs.find_or_initialize_by(key:).tap do |config|
      config.update!(value:)
    end
  end
end
