# frozen_string_literal: true

namespace :plans do
  # Billing belongs to the BILLING account: a testing or linked child is paid
  # for by its parent, and writing a subscription row on the child would put a
  # row where nothing reads it. Both tasks resolve first and say out loud
  # which account they wrote.
  def resolve_billing_account!(account_id)
    account = Account.find(account_id)
    billing = Plans.billing_account(account)

    unless billing.customer?
      abort "Account #{billing.id} is #{billing.account_kind}: it is always on the #{Plans::INTERNAL} plan."
    end

    puts "Billing account is ##{billing.id} (parent of ##{account.id})" unless billing.id == account.id

    billing
  end

  # A row Stripe is driving is not the operator's to edit: writing 'manual'
  # over it would take it out of the nightly sweep while Stripe kept charging
  # the card, and setting it back to cancelled would be undone by the next
  # webhook. Stripe cancels Stripe subscriptions.
  #
  # "Stripe is driving it" means exactly one thing: the raw Stripe status
  # last seen is live. A row the operator granted (`manual`) is always the
  # operator's, whatever stale ids it still carries, and a paid access_state
  # on its own proves nothing about Stripe.
  def refuse_stripe_backed!(subscription, action)
    return if subscription.nil? || subscription.status == 'manual'
    return unless StripeBilling::SubscriptionPolicy.live_status?(subscription.stripe_status)

    abort "Account #{subscription.account_id} has a live Stripe subscription " \
          "(#{subscription.stripe_subscription_id}, #{subscription.stripe_status}): " \
          "do not #{action} it by hand — cancel it at Stripe (Customer Portal or dashboard) " \
          'and the webhook downgrades the account.'
  end

  desc 'Put a customer account on the paid plan by hand: rake plans:grant[account_id,seats]'
  task :grant, %i[account_id seats] => :environment do |_, args|
    seats = args[:seats].presence&.to_i || 1

    abort 'seats must be at least 1' if seats < 1

    billing = resolve_billing_account!(args[:account_id])

    subscription = AccountSubscription.find_or_initialize_by(account: billing)

    refuse_stripe_backed!(subscription, 'grant')

    # A dead Stripe subscription's ids are cleared so the row cannot be
    # mistaken for Stripe-backed again; the customer id and the one-trial
    # stamp are the account's history and stay.
    subscription.update!(access_state: 'active', quantity: seats, status: 'manual', cancel_at_period_end: false,
                         stripe_subscription_id: nil, stripe_status: nil)

    puts "Account #{billing.id} plan: #{Plans.key_for(billing)} (#{seats} seats)"
  end

  desc 'Take a customer account off the paid plan: rake plans:revoke[account_id] (the row stays, D43)'
  task :revoke, %i[account_id] => :environment do |_, args|
    billing = resolve_billing_account!(args[:account_id])

    subscription = billing.account_subscription

    if subscription.nil?
      puts "Account #{billing.id} has no subscription; plan: #{Plans.key_for(billing)}"

      next
    end

    refuse_stripe_backed!(subscription, 'revoke')

    # A manual row's stale Stripe ids go with the grant they belonged to, so
    # the next grant is not mistaken for writing over a live subscription.
    stale_ids = subscription.status == 'manual' ? { stripe_subscription_id: nil, stripe_status: nil } : {}

    subscription.update!(access_state: 'cancelled', status: 'canceled', cancel_at_period_end: false, **stale_ids)

    puts "Account #{billing.id} plan: #{Plans.key_for(billing)}"
  end
end
