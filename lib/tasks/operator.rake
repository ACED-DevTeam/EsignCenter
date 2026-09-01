# frozen_string_literal: true

namespace :operator do
  desc 'Create the EsignCenter platform-operator account (requires OPERATOR_EMAIL and OPERATOR_PASSWORD)'
  task seed: :environment do
    email = ENV.fetch('OPERATOR_EMAIL', '').strip
    abort 'OPERATOR_EMAIL is required' if email.blank?

    # The password is never generated or printed: it must come from the
    # environment so it never lands in a log or a terminal scrollback.
    password = ENV.fetch('OPERATOR_PASSWORD', '')
    abort 'OPERATOR_PASSWORD is required (set it in the environment; it is never printed)' if password.blank?

    if Account.exists?(account_kind: Account::OPERATOR_KIND)
      puts 'An operator account already exists; no changes made.'
      next
    end

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

    puts "Created operator account #{account.id}."
  end
end
