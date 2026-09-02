# frozen_string_literal: true

# Which plan an account is on. Session 3 ships this as a STUB: internal and
# operator accounts are always on the internal plan, and a customer account is
# paid only when it carries the `plan_stub` account config (set with
# `rake plans:stub[account_id,paid]` for manual testing; there is no UI).
#
# Session 5 replaces the body of Plans.key_for with the real plan model
# (AccountSubscription); spec/golden/gating_spec.rb must pass unmodified
# afterwards. Nothing else in the codebase decides what plan an account is on —
# every entitlement check goes through Entitlements, which goes through here.
module Plans
  FREE = 'free'
  PAID = 'paid'
  INTERNAL = 'internal'

  KEYS = [FREE, PAID, INTERNAL].freeze

  # Plans that unlock every paid-only feature.
  PAID_OR_BETTER = [PAID, INTERNAL].freeze

  module_function

  # Internal and operator kinds are the platform itself, never a plan: they
  # resolve to INTERNAL. A customer account reads the stub on itself first,
  # then on its testing parent (Account#configuration_lookup_accounts, the
  # inheritance walk every other account config uses). No row means FREE.
  def key_for(account)
    return FREE if account.nil?
    return INTERNAL if account.internal? || account.operator?

    stub = AccountConfigs.find_for_account(account, AccountConfig::PLAN_STUB_KEY)&.value

    stub == PAID ? PAID : FREE
  end

  def paid_or_better?(account)
    PAID_OR_BETTER.include?(key_for(account))
  end
end
