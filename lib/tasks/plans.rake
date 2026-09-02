# frozen_string_literal: true

namespace :plans do
  desc 'Put a customer account on the paid plan by hand: rake plans:grant[account_id,seats]'
  task :grant, %i[account_id seats] => :environment do |_, args|
    account = Account.find(args[:account_id])
    seats = args[:seats].presence&.to_i || 1

    abort 'seats must be at least 1' if seats < 1

    unless account.customer?
      abort "Account #{account.id} is #{account.account_kind}: it is always on the #{Plans::INTERNAL} plan."
    end

    subscription = AccountSubscription.find_or_initialize_by(account:)
    subscription.update!(access_state: 'active', quantity: seats, status: 'manual', cancel_at_period_end: false)

    puts "Account #{account.id} plan: #{Plans.key_for(account)} (#{seats} seats)"
  end

  desc 'Take a customer account off the paid plan: rake plans:revoke[account_id] (the row stays, D43)'
  task :revoke, %i[account_id] => :environment do |_, args|
    account = Account.find(args[:account_id])

    unless account.customer?
      abort "Account #{account.id} is #{account.account_kind}: it is always on the #{Plans::INTERNAL} plan."
    end

    subscription = account.account_subscription

    if subscription.nil?
      puts "Account #{account.id} has no subscription; plan: #{Plans.key_for(account)}"

      next
    end

    subscription.update!(access_state: 'cancelled', status: 'canceled', cancel_at_period_end: false)

    puts "Account #{account.id} plan: #{Plans.key_for(account)}"
  end
end
