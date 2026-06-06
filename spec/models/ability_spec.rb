# frozen_string_literal: true

require 'cancan/matchers'

describe Ability do
  subject(:ability) { described_class.new(user) }

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }

  describe 'admin role' do
    let(:user) { create(:user, :admin, account:) }
    let(:other_user) { create(:user, account:) }

    it 'can manage documents' do
      expect(ability).to be_able_to(:create, Template.new(account_id: account.id))
      expect(ability).to be_able_to(:destroy, Template.new(account_id: account.id))
      expect(ability).to be_able_to(:manage, Submission.new(account_id: account.id))
      expect(ability).to be_able_to(:manage, Submitter.new(account_id: account.id))
    end

    it 'can administer the account, users, tokens and webhooks' do
      expect(ability).to be_able_to(:manage, account)
      expect(ability).to be_able_to(:manage, other_user)
      expect(ability).to be_able_to(:manage, AccountConfig.new(account_id: account.id))
      expect(ability).to be_able_to(:manage, WebhookUrl.new(account_id: account.id))
      expect(ability).to be_able_to(:manage, user.access_token)
    end

    it 'cannot reach another account' do
      expect(ability).not_to be_able_to(:read, Template.new(account_id: other_account.id))
      expect(ability).not_to be_able_to(:manage, other_account)
    end
  end

  describe 'editor role' do
    let(:user) { create(:user, :editor, account:) }
    let(:other_user) { create(:user, account:) }

    it 'can manage documents' do
      expect(ability).to be_able_to(:create, Template.new(account_id: account.id))
      expect(ability).to be_able_to(:update, Template.new(account_id: account.id))
      expect(ability).to be_able_to(:destroy, Template.new(account_id: account.id))
      expect(ability).to be_able_to(:manage, Submission.new(account_id: account.id))
      expect(ability).to be_able_to(:manage, Submitter.new(account_id: account.id))
    end

    it 'can manage its own profile and personal settings' do
      expect(ability).to be_able_to(:manage, user)
      expect(ability).to be_able_to(:manage, UserConfig.new(user_id: user.id))
    end

    it 'cannot administer the account' do
      expect(ability).not_to be_able_to(:read, account)
      expect(ability).not_to be_able_to(:manage, account)
      expect(ability).not_to be_able_to(:manage, AccountConfig.new(account_id: account.id))
      expect(ability).not_to be_able_to(:manage, EncryptedConfig.new(account_id: account.id))
      expect(ability).not_to be_able_to(:manage, WebhookUrl.new(account_id: account.id))
    end

    it 'cannot manage other users or API tokens' do
      expect(ability).not_to be_able_to(:update, other_user)
      expect(ability).not_to be_able_to(:create, User.new(account_id: account.id))
      expect(ability).not_to be_able_to(:manage, user.access_token)
    end
  end

  describe 'viewer role' do
    let(:user) { create(:user, :viewer, account:) }
    let(:other_user) { create(:user, account:) }

    it 'can read documents' do
      expect(ability).to be_able_to(:read, Template.new(account_id: account.id))
      expect(ability).to be_able_to(:read, Submission.new(account_id: account.id))
      expect(ability).to be_able_to(:read, Submitter.new(account_id: account.id))
    end

    it 'cannot modify documents' do
      expect(ability).not_to be_able_to(:create, Template.new(account_id: account.id))
      expect(ability).not_to be_able_to(:update, Template.new(account_id: account.id))
      expect(ability).not_to be_able_to(:destroy, Template.new(account_id: account.id))
      expect(ability).not_to be_able_to(:create, Submission.new(account_id: account.id))
      expect(ability).not_to be_able_to(:update, Submitter.new(account_id: account.id))
    end

    it 'can manage its own profile' do
      expect(ability).to be_able_to(:manage, user)
    end

    it 'cannot administer the account or manage other users' do
      expect(ability).not_to be_able_to(:manage, account)
      expect(ability).not_to be_able_to(:update, other_user)
      expect(ability).not_to be_able_to(:manage, user.access_token)
    end
  end

  describe 'integration and legacy roles keep full access' do
    let(:user) { create(:user, account:, role: 'integration') }

    it 'behaves like an admin (no regression for API users)' do
      expect(ability).to be_able_to(:create, Template.new(account_id: account.id))
      expect(ability).to be_able_to(:manage, account)
      expect(ability).to be_able_to(:manage, WebhookUrl.new(account_id: account.id))
    end
  end
end
