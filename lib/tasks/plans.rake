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

  desc 'Put a customer account on the paid plan by hand: rake plans:grant[account_id,seats]'
  task :grant, %i[account_id seats] => :environment do |_, args|
    seats = args[:seats].presence&.to_i || 1

    abort 'seats must be at least 1' if seats < 1

    billing = resolve_billing_account!(args[:account_id])

    subscription = AccountSubscription.find_or_initialize_by(account: billing)
    subscription.update!(access_state: 'active', quantity: seats, status: 'manual', cancel_at_period_end: false)

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

    subscription.update!(access_state: 'cancelled', status: 'canceled', cancel_at_period_end: false)

    puts "Account #{billing.id} plan: #{Plans.key_for(billing)}"
  end
end
