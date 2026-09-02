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

    existing_account = OperatorConfigs.account

    if existing_account
      adopted = OperatorSeed.adopt_legacy_fulltext_flag(existing_account)

      puts 'An operator account already exists; no changes made.' unless adopted

      # The platform signing certificate is generated once, on the operator
      # account, and only here: a re-run leaves the existing row alone.
      PlatformCertificate.ensure!

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

    # Generated once, here and nowhere else; `rake operator:platform_cert:fingerprint`
    # prints its fingerprint and `…:export` writes the offline custody copy.
    PlatformCertificate.ensure!
  end

  namespace :platform_cert do
    desc 'Print the SHA-256 fingerprint of the platform signing certificate'
    task fingerprint: :environment do
      puts PlatformCertificate.fingerprint
    end

    desc 'Write the platform signing certificate (and its keys) to PATH as a 0600 PEM bundle for offline custody'
    task :export, [:path] => :environment do |_task, args|
      path = args[:path].to_s
      abort 'PATH is required: rake "operator:platform_cert:export[/secure/path/platform-cert.pem]"' if path.blank?

      pems = PlatformCertificate.pems
      # Written 0600 before a single byte of key material lands in it.
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(PlatformCertificate::EXPORT_ORDER.filter_map { |key| pems[key] }.join)
      end
      File.chmod(0o600, path)

      # Never the key material itself: only what identifies the bundle.
      puts "Platform signing certificate fingerprint: #{PlatformCertificate.fingerprint}"
      puts "Wrote #{File.size(path)} bytes to #{path} (mode 0600)."
    end
  end
end
