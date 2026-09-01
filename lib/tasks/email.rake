# frozen_string_literal: true

namespace :email do
  desc 'Pin an account to its own SMTP server'
  task pin: :environment do
    account_id = ENV['ACCOUNT_ID'].presence || abort('ACCOUNT_ID is required')
    token_env = ENV['SMTP_TOKEN_ENV'].presence || abort('SMTP_TOKEN_ENV is required')
    token = ENV[token_env].presence || abort("#{token_env} is empty")
    from_email = ENV['FROM_EMAIL'].presence || abort('FROM_EMAIL is required')
    host = ENV['SMTP_HOST'].presence || 'smtp.postmarkapp.com'
    port = ENV['SMTP_PIN_PORT'].presence || '587'

    account = Account.find_by(id: account_id) || abort("Account #{account_id} was not found")
    config = EncryptedConfig.find_or_initialize_by(account:, key: EncryptedConfig::EMAIL_SMTP_KEY)

    config.update!(
      value: {
        'host' => host,
        'port' => port,
        'username' => token,
        'password' => token,
        'from_email' => from_email,
        'authentication' => 'plain'
      }
    )

    puts "Pinned SMTP for account #{account.id} to #{host}."
  end

  desc 'Remove an account-specific SMTP server pin'
  task unpin: :environment do
    account_id = ENV['ACCOUNT_ID'].presence || abort('ACCOUNT_ID is required')
    account = Account.find_by(id: account_id) || abort("Account #{account_id} was not found")
    config = EncryptedConfig.find_by(account:, key: EncryptedConfig::EMAIL_SMTP_KEY)

    if config
      config.destroy!
      puts "Removed SMTP pin for account #{account.id}."
    else
      puts "Account #{account.id} has no SMTP pin; no changes made."
    end
  end
end
