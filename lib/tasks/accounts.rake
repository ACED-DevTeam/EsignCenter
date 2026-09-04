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

    # The claim, exactly as AccountPurgeJob stamps it (review batch 2, R3):
    # this door destroys just as thoroughly, so it must close the same
    # barriers first — sign-in, signer writes, tokens, the quota chokepoint —
    # and it must release them again if the purge refuses.
    Accounts::Purge.claim!(account)

    result =
      begin
        Accounts::Purge.call(account)
      rescue Accounts::Purge::Refused, Accounts::Purge::StorageFailure => e
        Accounts::Purge.release_claim!(account)

        abort "#{e.message}\n(The purge claim has been released; the account is usable again.)"
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

    # Branch on the answer rather than printing success over a refusal (R3):
    # once the purge has claimed the account there is nothing whole left to
    # restore, and saying "cancelled" would send somebody away believing their
    # documents were safe.
    begin
      unless Accounts::Deletion.cancel!(account)
        abort "Account ##{account.id} is already being purged (claimed at #{account.reload.purge_started_at}) " \
              'and cannot be restored. If the purge is stuck rather than running, release the claim with ' \
              "rake accounts:release_purge_claim[#{account.id}] and look at why it failed."
      end
    rescue Accounts::Deletion::BillingUnsettled => e
      # The subscription was cancelled at Stripe when the deletion was asked
      # for, but the local row has not caught up, so unfreezing the account
      # now would give it paid features nobody is being charged for. Nothing
      # was changed; try again once the retrying job has been through.
      abort "Account ##{account.id} was left alone: #{e.message}. Nothing was cancelled. " \
            'Wait for CancelDeletedSubscriptionJob (or the nightly Stripe reconciliation) and run this again.'
    end

    puts "Cancelled the deletion of account ##{account.id}, which was scheduled for #{scheduled}."
    puts 'The subscription was cancelled when the deletion was requested and does NOT come back: ' \
         'the account is on the free plan until somebody subscribes again.'
  end

  desc 'Release a stuck purge claim so the account works again: rake accounts:release_purge_claim[account_id]'
  task :release_purge_claim, [:account_id] => :environment do |_, args|
    account = Account.find(args[:account_id])

    abort "Account ##{account.id} has already been purged; there is no claim to release." if account.purged?
    abort "Account ##{account.id} is not claimed by a purge." if account.purge_started_at.blank?

    claimed_at = account.purge_started_at

    Accounts::Purge.release_claim!(account)

    puts "Released the purge claim on account ##{account.id} (claimed at #{claimed_at})."
    puts 'Sign-in, signer writes and the API work again. NOTE: if the purge had already started deleting, ' \
         'the account is PART-EMPTIED — check before handing it back to the customer.'
  end
end
