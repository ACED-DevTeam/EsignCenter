# frozen_string_literal: true

namespace :operator do
  desc 'Create the EsignCenter platform-operator account'
  task seed: :environment do
    email = ENV.fetch('OPERATOR_EMAIL', '').strip
    abort 'OPERATOR_EMAIL is required' if email.blank?

    if Account.exists?(account_kind: Account::OPERATOR_KIND)
      puts 'An operator account already exists; no changes made.'
      next
    end

    generated_password = ENV['OPERATOR_PASSWORD'].blank?
    password = ENV['OPERATOR_PASSWORD'].presence || SecureRandom.base58(24)

    account = ApplicationRecord.transaction do
      operator_account = Account.create!(
        name: 'EsignCenter Operations',
        account_kind: Account::OPERATOR_KIND
      )
      user = operator_account.users.new(
        email:,
        password:,
        role: User::ADMIN_ROLE,
        platform_operator: true
      )
      user.skip_confirmation!
      user.save!

      operator_account
    end

    puts "Generated operator password: #{password}" if generated_password
    puts "Created operator account #{account.id}."
  end
end
