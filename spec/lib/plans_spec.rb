# frozen_string_literal: true

RSpec.describe Plans, type: :lib do
  it 'names exactly the three plan keys and the access states' do
    expect(described_class::KEYS).to eq(%w[free paid internal])
    expect(described_class::PAID_OR_BETTER).to eq(%w[paid internal])
    expect(described_class::ACCESS_STATES).to eq(%w[trialing active canceling past_due suspended cancelled])
    expect(described_class::PAID_ACCESS_STATES).to eq(%w[trialing active canceling past_due])
  end

  describe '.key_for' do
    it 'resolves a missing account to free' do
      expect(described_class.key_for(nil)).to eq(described_class::FREE)
    end

    it 'resolves a customer account with no subscription row to the free plan' do
      expect(described_class.key_for(create(:account))).to eq(described_class::FREE)
    end

    it 'resolves the paid trait (an active subscription) to the paid plan' do
      expect(described_class.key_for(create(:account, :paid))).to eq(described_class::PAID)
    end

    it 'reads each access state: trialing, active, canceling and past_due are paid; suspended and cancelled are free' do
      account = create(:account)
      subscription = create(:account_subscription, account:)

      described_class::ACCESS_STATES.each do |state|
        subscription.update!(access_state: state)
        account.reload

        expected = described_class::PAID_ACCESS_STATES.include?(state) ? described_class::PAID : described_class::FREE

        expect(described_class.key_for(account)).to eq(expected), "#{state} should read as #{expected}"
      end
    end

    it 'keeps the row on a downgrade (D43) and reads it as free' do
      account = create(:account, :paid)

      downgrade_to_free!(account)

      expect(account.reload.account_subscription).to be_present
      expect(described_class.key_for(account)).to eq(described_class::FREE)
    end

    it 'resolves internal and operator kinds to the internal plan regardless of any subscription row' do
      internal = create(:account, :internal)
      operator = create(:account, :operator)
      create(:account_subscription, account: internal, access_state: 'cancelled')

      expect(described_class.key_for(internal)).to eq(described_class::INTERNAL)
      expect(described_class.key_for(operator)).to eq(described_class::INTERNAL)
    end

    it 'lets both a testing child and a linked child inherit the parent subscription' do
      parent = create(:account, :paid, :with_testing_account)
      testing_child = parent.testing_accounts.sole

      linked_parent = create(:account, :paid)
      linked_child = create(:account)
      AccountLinkedAccount.create!(account: linked_parent, linked_account: linked_child, account_type: 'linked')

      free_parent = create(:account)
      free_child = create(:account)
      AccountLinkedAccount.create!(account: free_parent, linked_account: free_child, account_type: 'linked')

      expect(described_class.key_for(testing_child)).to eq(described_class::PAID)
      expect(described_class.key_for(linked_child)).to eq(described_class::PAID)
      expect(described_class.key_for(free_child)).to eq(described_class::FREE)
    end
  end

  describe '.billing_account' do
    it 'is the account itself unless it is another account\'s child' do
      parent = create(:account, :with_testing_account)
      child = parent.testing_accounts.sole

      expect(described_class.billing_account(parent)).to eq(parent)
      expect(described_class.billing_account(child)).to eq(parent)
    end
  end

  describe '.seats_for' do
    it 'is unlimited for internal, the subscription quantity for paid, and the free constant otherwise' do
      expect(described_class.seats_for(create(:account, :internal))).to be_nil
      expect(described_class.seats_for(create(:account, :paid, seats: 3))).to eq(3)
      expect(described_class.seats_for(create(:account))).to eq(Quotas::Limits::FREE_SEATS)
    end
  end

  describe '.paid_or_better?' do
    it 'is true for paid and internal, false for free' do
      expect(described_class.paid_or_better?(create(:account, :paid))).to be(true)
      expect(described_class.paid_or_better?(create(:account, :internal))).to be(true)
      expect(described_class.paid_or_better?(create(:account))).to be(false)
    end
  end
end
