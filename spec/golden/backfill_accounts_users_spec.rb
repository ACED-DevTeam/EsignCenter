# frozen_string_literal: true

require Rails.root.join('db/migrate/20260901090100_backfill_account_kinds_and_user_confirmations.rb')

# Every account that existed before account kinds were introduced belongs to
# Evan's own apps, so all of them become 'internal'. Devise :confirmable
# arrives with allow_unconfirmed_access_for = 0.days, so every pre-existing
# user must be confirmed by the migration or they are locked out at deploy.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Account kind and user confirmation backfill' do
  let(:migration) { BackfillAccountKindsAndUserConfirmations.new }

  def run_backfill
    ActiveRecord::Migration.suppress_messages { migration.up }
  end

  it 'promotes a pre-existing customer-kind account to internal' do
    account = create(:account)
    account.update_column(:account_kind, Account::CUSTOMER_KIND)

    expect(account.reload.account_kind).to eq(Account::CUSTOMER_KIND)

    run_backfill

    expect(account.reload.account_kind).to eq(Account::INTERNAL_KIND)
    expect(Account.where.not(account_kind: Account::INTERNAL_KIND)).to be_empty
  end

  it 'confirms an unconfirmed user at their creation time and leaves a confirmed user untouched' do
    created_at = Time.zone.parse('2025-03-04 05:06:07')
    unconfirmed_user = create(:user)
    unconfirmed_user.update_columns(confirmed_at: nil, created_at:)
    confirmed_at = Time.zone.parse('2024-01-02 03:04:05')
    confirmed_user = create(:user)
    confirmed_user.update_column(:confirmed_at, confirmed_at)

    expect(unconfirmed_user.reload).not_to be_confirmed

    run_backfill

    expect(unconfirmed_user.reload).to be_confirmed
    expect(unconfirmed_user.confirmed_at).to eq(created_at)
    expect(confirmed_user.reload.confirmed_at).to eq(confirmed_at)
    expect(User.where(confirmed_at: nil)).to be_empty
  end

  it 'cannot be rolled back' do
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
# rubocop:enable RSpec/DescribeClass
