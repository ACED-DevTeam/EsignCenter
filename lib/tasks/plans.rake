# frozen_string_literal: true

namespace :plans do
  # Both tasks are thin doors onto Plans::Manual, which is the ONE place the
  # manual grant and revoke live (the operator console's Comp panel is the
  # other door onto it). Everything these tasks add is reporting: which
  # account was actually written, and turning a refusal into an abort.
  def manual_billing_account(account_id)
    account = Account.find(account_id)
    billing = Plans::Manual.billing_account!(account)

    puts "Billing account is ##{billing.id} (parent of ##{account.id})" unless billing.id == account.id

    billing
  rescue Plans::Manual::Refused => e
    abort e.message
  end

  desc 'Put a customer account on the paid plan by hand: rake plans:grant[account_id,seats]'
  task :grant, %i[account_id seats] => :environment do |_, args|
    seats = args[:seats].presence&.to_i || 1

    abort 'seats must be at least 1' if seats < 1

    billing = manual_billing_account(args[:account_id])

    begin
      Plans::Manual.grant!(billing, seats:)
    rescue Plans::Manual::Refused => e
      abort e.message
    end

    puts "Account #{billing.id} plan: #{Plans.key_for(billing.reload)} (#{seats} seats)"
  end

  desc 'Take a customer account off the paid plan: rake plans:revoke[account_id] (the row stays, D43)'
  task :revoke, %i[account_id] => :environment do |_, args|
    billing = manual_billing_account(args[:account_id])

    if billing.account_subscription.nil?
      puts "Account #{billing.id} has no subscription; plan: #{Plans.key_for(billing)}"

      next
    end

    begin
      Plans::Manual.revoke!(billing)
    rescue Plans::Manual::Refused => e
      abort e.message
    end

    puts "Account #{billing.id} plan: #{Plans.key_for(billing.reload)}"
  end
end
