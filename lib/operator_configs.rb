# frozen_string_literal: true

# Instance-global settings live as AccountConfig rows on the platform-operator
# account. This module is the ONE place those rows are read or written, and
# every read is scoped to that account — never to the lowest-id account.
module OperatorConfigs
  class MissingOperatorAccountError < StandardError; end

  module_function

  def account
    Account.find_by(account_kind: Account::OPERATOR_KIND)
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
