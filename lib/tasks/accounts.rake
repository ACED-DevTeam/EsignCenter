# frozen_string_literal: true

namespace :accounts do
  # The operator's two doors into the deletion flow (docs/account-deletion.md).
  # Both take an account id and both say out loud what they did, because the
  # first one cannot be undone.

  desc 'Permanently destroy one account now, skipping the rest of its 90-day window: rake accounts:purge[account_id]'
  task :purge, [:account_id] => :environment do |_, args|
    account = Account.find(args[:account_id])

    puts "Account ##{account.id} (#{account.name}), kind #{account.account_kind}"
    puts "  deletion requested: #{account.deletion_requested_at || '(never)'}"
    puts "  scheduled purge:    #{account.purge_scheduled_for || '(none)'}"

    result =
      begin
        Accounts::Purge.call(account)
      rescue Accounts::Purge::Refused => e
        abort e.message
      end

    if result == :already_purged
      puts 'Already purged; nothing to do.'
    else
      puts 'Purged.'
    end

    # The proof, printed rather than assumed: four tables with no foreign key
    # to `accounts`, so nothing in the database would have complained if the
    # walk had missed one.
    Accounts::Purge.orphans(account.id).each { |table, count| puts "  #{table}: #{count}" }
  end

  desc 'Call off a scheduled account deletion on the customer\'s behalf: rake accounts:cancel_deletion[account_id]'
  task :cancel_deletion, [:account_id] => :environment do |_, args|
    account = Account.find(args[:account_id])

    abort "Account ##{account.id} has already been purged; there is nothing to call off." if account.purged?
    abort "Account ##{account.id} is not scheduled for deletion." unless account.pending_deletion?

    scheduled = account.purge_scheduled_for

    Accounts::Deletion.cancel!(account)

    puts "Cancelled the deletion of account ##{account.id}, which was scheduled for #{scheduled}."
    puts 'The subscription was cancelled when the deletion was requested and does NOT come back: ' \
         'the account is on the free plan until somebody subscribes again.'
  end
end
