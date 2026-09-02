# frozen_string_literal: true

namespace :plans do
  desc 'Set the Session 3 plan stub for a customer account: rake plans:stub[account_id,paid|free]'
  task :stub, %i[account_id plan] => :environment do |_, args|
    account = Account.find(args[:account_id])
    plan = args[:plan].to_s

    abort "plan must be #{Plans::PAID} or #{Plans::FREE}" unless plan.in?([Plans::PAID, Plans::FREE])

    if account.internal? || account.operator?
      puts "Account #{account.id} is #{account.account_kind}: it is always on the #{Plans::INTERNAL} plan."

      next
    end

    config = account.account_configs.find_or_initialize_by(key: AccountConfig::PLAN_STUB_KEY)

    # Free is the absence of a stub row, so setting free removes it; both
    # directions are idempotent.
    if plan == Plans::FREE
      config.destroy! if config.persisted?
    else
      config.update!(value: plan)
    end

    puts "Account #{account.id} plan: #{Plans.key_for(account)}"
  end
end
