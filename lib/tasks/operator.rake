# frozen_string_literal: true

module OperatorSeed
  module_function

  # Before Session 2 the fulltext toggle was a global flag stored on the
  # lowest-id account. Reads are now scoped to the operator account, which
  # only exists once this task has run — so a fresh operator account would
  # silently switch search off at deploy. Adopt the legacy flag onto the
  # operator account until it reads true (a false or missing operator row is
  # adopted over); the legacy row is left untouched.
  def adopt_legacy_fulltext_flag(operator_account)
    return false unless SearchEntry.table_exists?
    return false if OperatorConfigs.enabled?(:fulltext_search)

    legacy_config = AccountConfig.where(key: 'fulltext_search', value: true)
                                 .where.not(account_id: operator_account.id)
                                 .where.not(account_id: Account.testing_child_ids)
                                 .order(:id)
                                 .first

    return false if legacy_config.nil?

    OperatorConfigs.set!(:fulltext_search, true)
    Docuseal.refresh_fulltext_search!

    puts "fulltext search flag adopted from legacy account #{legacy_config.account_id}"

    true
  end
end

namespace :operator do
  desc 'Create the EsignCenter platform-operator account (requires OPERATOR_EMAIL and OPERATOR_PASSWORD)'
  task seed: :environment do
    email = ENV.fetch('OPERATOR_EMAIL', '').strip
    abort 'OPERATOR_EMAIL is required' if email.blank?

    # The password is never generated or printed: it must come from the
    # environment so it never lands in a log or a terminal scrollback.
    password = ENV.fetch('OPERATOR_PASSWORD', '')
    abort 'OPERATOR_PASSWORD is required (set it in the environment; it is never printed)' if password.blank?

    if (existing_account = OperatorConfigs.account)
      adopted = OperatorSeed.adopt_legacy_fulltext_flag(existing_account)

      puts 'An operator account already exists; no changes made.' unless adopted

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

    OperatorSeed.adopt_legacy_fulltext_flag(account)
  end
end
