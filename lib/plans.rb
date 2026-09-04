# frozen_string_literal: true

# Which plan an account is on. Internal and operator accounts are the platform
# itself and always resolve to the internal plan; a customer account is paid
# while its subscription row (AccountSubscription) sits in one of the
# PAID_ACCESS_STATES, and free otherwise — no row, a cancelled row, a
# suspended row all read as free. A downgrade never deletes the row (D43).
#
# Billing is per BILLING account: an account that exists as another account's
# child (a testing child or a linked "team" account) is billed through its
# parent, so the parent's subscription covers it and the parent's kind decides
# the plan. `billing_account` is that resolution; Quotas counts usage against
# the same account so a child's documents roll up to the parent's limits.
#
# Nothing else in the codebase decides what plan an account is on — every
# entitlement check goes through Entitlements, which goes through here.
module Plans
  FREE = 'free'
  PAID = 'paid'
  INTERNAL = 'internal'

  KEYS = [FREE, PAID, INTERNAL].freeze

  # Plans that unlock every paid-only feature.
  PAID_OR_BETTER = [PAID, INTERNAL].freeze

  # The app's own verdict on a subscription (AccountSubscription#access_state).
  # Session 6 drives it from Stripe webhooks; `rake plans:grant` / `plans:revoke`
  # set it by hand.
  ACCESS_STATES = %w[trialing active canceling past_due suspended cancelled].freeze

  # Access states under which the paid features stay on: a trial, a live
  # subscription, one that cancels at period end, and one whose renewal is
  # late but not yet given up on.
  PAID_ACCESS_STATES = %w[trialing active canceling past_due].freeze

  module_function

  def key_for(account)
    return FREE if account.nil?

    billing = billing_account(account)

    return INTERNAL unless billing.customer?

    paid_subscription?(billing) ? PAID : FREE
  end

  def paid_or_better?(account)
    PAID_OR_BETTER.include?(key_for(account))
  end

  # The account that is billed for `account`: itself, unless it is another
  # account's child (testing or linked), in which case the parent.
  def billing_account(account)
    account.linked_account_account&.account || account
  end

  # How many seats the account may fill: nil means unlimited. One answer for
  # the whole app — the quota engine's, override included.
  def seats_for(account)
    Quotas.limits_for(account).seats
  end

  def paid_subscription?(billing)
    PAID_ACCESS_STATES.include?(billing.account_subscription&.access_state)
  end

  # A subscription that is still ALIVE at Stripe, as opposed to one this app
  # currently counts as paid. The two are NOT the same question, and asking
  # the paid one where the live one was meant is how an account gets destroyed
  # while its card is still being charged.
  #
  # StripeBilling::SubscriptionSync maps Stripe's `unpaid` and `paused` to a
  # local access_state of `suspended`, and `incomplete` to `cancelled` — none
  # of them in PAID_ACCESS_STATES, so `paid_subscription?` says no. But
  # StripeBilling::SubscriptionPolicy classifies all three as LIVE: an unpaid
  # or paused subscription can be resumed from the customer portal, and an
  # incomplete one is a first payment that has not finished, not one that
  # failed. Every one of them can still move money.
  #
  # This is the ROW's answer, never a call to Stripe: it is the cheap verdict
  # the billing page and the Checkout pre-check already use, and for anything
  # irreversible (archiving an account underneath a subscription, destroying
  # one) refusing is the safe direction — a false "still live" costs somebody
  # a support ticket, a false "already dead" costs a customer their money or
  # their documents.
  #
  # Lives here rather than in StripeBilling because it is an ACCOUNT-level
  # question and this is the module the whole app asks account-level
  # subscription questions of; `Linker.holds_live_subscription?` beneath it
  # takes the row.
  def live_subscription?(account)
    row = account&.account_subscription

    return false if row.nil?

    paid_subscription?(account) || StripeBilling::Linker.holds_live_subscription?(row)
  end
end
