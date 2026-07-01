# frozen_string_literal: true

# One-time backfill: turn on per-signature audit stamping (the signature
# ID/reason stamp + the "Document ID" page footer) for firm accounts that were
# provisioned by the upstream app before this default was added.
#
# Idempotent and safe to re-run: it skips any account that already has the
# `with_signature_id` config set (in either direction), so it never overrides a
# choice someone made by hand.
#
# By default it only touches accounts provisioned by the upstream app (their
# admin user email looks like `esign-<id>@...`). Pass ALL_ACCOUNTS=1 to apply it
# to every account on this server instead.
#
#   bundle exec rake audit_stamping:enable
#   ALL_ACCOUNTS=1 bundle exec rake audit_stamping:enable
namespace :audit_stamping do
  desc 'Enable signature-ID audit stamping on existing provisioned firm accounts'
  task enable: :environment do
    scope =
      if ENV['ALL_ACCOUNTS'].present?
        Account.all
      else
        Account.where(id: User.where('email LIKE ?', 'esign-%').select(:account_id))
      end

    enabled = 0
    skipped = 0

    scope.find_each do |account|
      if account.account_configs.exists?(key: AccountConfig::WITH_SIGNATURE_ID)
        skipped += 1
        next
      end

      account.account_configs.create!(key: AccountConfig::WITH_SIGNATURE_ID, value: true)
      enabled += 1
    end

    puts "audit_stamping: enabled on #{enabled} account(s), skipped #{skipped} already-configured account(s)."
  end
end
