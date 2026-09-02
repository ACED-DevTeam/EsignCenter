# frozen_string_literal: true

RSpec.describe Plans, type: :lib do
  it 'names exactly the three plan keys' do
    expect(described_class::KEYS).to eq(%w[free paid internal])
    expect(described_class::PAID_OR_BETTER).to eq(%w[paid internal])
  end

  describe '.key_for' do
    it 'resolves a customer account with no stub to the free plan' do
      expect(described_class.key_for(create(:account))).to eq(described_class::FREE)
    end

    it 'resolves a customer account carrying the paid stub to the paid plan' do
      expect(described_class.key_for(create(:account, :paid))).to eq(described_class::PAID)
    end

    it 'treats any other stub value as free' do
      account = create(:account)
      create(:account_config, account:, key: AccountConfig::PLAN_STUB_KEY, value: 'enterprise')

      expect(described_class.key_for(account)).to eq(described_class::FREE)
    end

    it 'resolves internal and operator kinds to the internal plan regardless of any stub' do
      internal = create(:account, :internal)
      operator = create(:account, :operator)
      create(:account_config, account: internal, key: AccountConfig::PLAN_STUB_KEY, value: 'free')

      expect(described_class.key_for(internal)).to eq(described_class::INTERNAL)
      expect(described_class.key_for(operator)).to eq(described_class::INTERNAL)
    end

    it 'lets a testing child inherit the stub from its testing parent, but never from a linked parent' do
      parent = create(:account, :paid, :with_testing_account)
      testing_child = parent.testing_accounts.sole

      linked_parent = create(:account, :paid)
      linked_child = create(:account)
      AccountLinkedAccount.create!(account: linked_parent, linked_account: linked_child, account_type: 'linked')

      expect(described_class.key_for(testing_child)).to eq(described_class::PAID)
      expect(described_class.key_for(linked_child)).to eq(described_class::FREE)
    end

    it 'resolves a missing account to free' do
      expect(described_class.key_for(nil)).to eq(described_class::FREE)
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
