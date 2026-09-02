# frozen_string_literal: true

require 'rake'

# Platform-operator surfaces: the Sidekiq console and the instance-global
# fulltext toggle open only for a user flagged by `rake operator:seed` who has
# enrolled 2FA. Everyone else gets a 404 — the route does not exist for them —
# and no HTTP path can create or promote an operator.
RSpec.describe 'Operator access', type: :request do
  def enroll_two_factor(user)
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)

    user
  end

  # Mirrors how test mode clones an account: the child carries the parent's
  # account_kind, which is exactly why the kind can never be the gate.
  def create_testing_child(parent)
    child = parent.dup.tap { |account| account.name = "Testing - #{parent.name}" }
    child.uuid = SecureRandom.uuid
    parent.testing_accounts << child
    parent.save!

    child
  end

  let(:operator_account) { create(:account, :operator) }
  let(:operator) { enroll_two_factor(create(:user, :admin, account: operator_account, platform_operator: true)) }
  let(:customer_admin) { create(:user, :admin, account: create(:account)) }
  let(:internal_admin) { create(:user, :admin, account: create(:account, :internal)) }

  after { Docuseal.refresh_fulltext_search! }

  describe 'GET /jobs' do
    it 'serves the console to a platform operator with 2FA' do
      sign_in(operator)

      get '/jobs'

      expect(response).to have_http_status(:ok)
    end

    it 'has no route for an anonymous visitor' do
      expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
    end

    it 'has no route for a customer admin' do
      sign_in(customer_admin)

      expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
    end

    it 'has no route for an internal admin' do
      sign_in(internal_admin)

      expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
    end

    it 'has no route for an operator-flagged user without 2FA' do
      sign_in(create(:user, :admin, account: operator_account, platform_operator: true))

      expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
    end

    # An account admin can flip otp_required_for_login on another user; only
    # real enrollment leaves a secret behind, so the flag alone is not 2FA.
    it 'has no route for an operator-flagged user whose 2FA flag has no secret' do
      flagged_only = create(:user, :admin, account: operator_account, platform_operator: true)
      flagged_only.update!(otp_required_for_login: true, otp_secret: nil)

      sign_in(flagged_only)

      expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
    end

    it 'has no route for an admin inside a testing child of the operator account' do
      testing_child = create_testing_child(operator_account)
      testing_admin = enroll_two_factor(create(:user, :admin, account: testing_child))

      expect(testing_child.account_kind).to eq(Account::OPERATOR_KIND)
      expect(testing_admin.platform_operator).to be(false)

      sign_in(testing_admin)

      expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
    end
  end

  describe 'POST /settings/search_entries_reindex' do
    it 'is a 404 for a customer admin and writes nothing' do
      operator_account
      sign_in(customer_admin)

      expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
      expect(ReindexAllSearchEntriesJob.jobs).to be_empty
    end

    it 'is a 404 for an internal admin and writes nothing' do
      operator_account
      sign_in(internal_admin)

      expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
      expect(ReindexAllSearchEntriesJob.jobs).to be_empty
    end

    it 'is an empty 404 for a non-HTML request' do
      operator_account
      sign_in(customer_admin)

      post settings_search_entries_reindex_index_path, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
    end

    it 'is a 404 for an anonymous visitor, never a redirect to sign-in' do
      operator_account

      expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
      expect(ReindexAllSearchEntriesJob.jobs).to be_empty
    end

    it 'is an empty 404 for an anonymous non-HTML request' do
      operator_account

      post settings_search_entries_reindex_index_path, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
    end

    it 'is a 404 for an operator-flagged user whose 2FA flag has no secret' do
      flagged_only = create(:user, :admin, account: operator_account, platform_operator: true)
      flagged_only.update!(otp_required_for_login: true, otp_secret: nil)
      sign_in(flagged_only)

      expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
    end

    it 'lets the operator start the reindex and lands the flag on the operator account only' do
      customer_admin
      internal_admin
      sign_in(operator)

      expect(Docuseal.fulltext_search?).to be(false)

      post settings_search_entries_reindex_index_path, headers: { 'HTTP_REFERER' => settings_account_path }

      expect(response).to redirect_to(settings_account_path)
      expect(ReindexAllSearchEntriesJob.jobs.size).to eq(1)

      flag_rows = AccountConfig.where(key: 'fulltext_search')

      expect(flag_rows.sole.account).to eq(operator_account)
      expect(flag_rows.sole.value).to be(true)
      expect(AccountConfig.where(key: 'fulltext_search').where.not(account: operator_account)).not_to exist
      expect(Docuseal.fulltext_search?).to be(true)
    end

    it 'keeps working for the operator in test mode and lands the flag on the real operator account' do
      sign_in(operator)

      post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

      expect(response).to have_http_status(:redirect)

      testing_child = operator_account.testing_accounts.reload.sole

      expect(testing_child.account_kind).to eq(Account::OPERATOR_KIND)
      expect(testing_child.users.sole.platform_operator).to be(false)
      expect(OperatorConfigs.candidates.pluck(:id)).to eq([operator_account.id])

      get '/jobs'

      expect(response).to have_http_status(:ok)

      post settings_search_entries_reindex_index_path, headers: { 'HTTP_REFERER' => settings_account_path }

      expect(response).to redirect_to(settings_account_path)
      expect(ReindexAllSearchEntriesJob.jobs.size).to eq(1)

      flag_rows = AccountConfig.where(key: 'fulltext_search')

      expect(flag_rows.sole.account).to eq(operator_account)
      expect(flag_rows.sole.value).to be(true)
      expect(testing_child.account_configs.where(key: 'fulltext_search')).not_to exist
      expect(Docuseal.fulltext_search?).to be(true)
    end

    it 'stays a 404 for an internal admin in test mode' do
      operator_account
      sign_in(internal_admin)

      post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

      expect(response).to have_http_status(:redirect)
      expect(internal_admin.account.testing_accounts.reload.size).to eq(1)

      expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
      expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
      expect(ReindexAllSearchEntriesJob.jobs).to be_empty
    end

    it 'shows the reindex control only to the operator' do
      operator_account

      sign_in(internal_admin)
      get settings_account_path
      expect(response.body).not_to include(settings_search_entries_reindex_index_path)

      sign_in(operator)
      get settings_account_path
      expect(response.body).to include(settings_search_entries_reindex_index_path)
    end
  end

  describe 'OperatorConfigs' do
    # Test mode clones the operator account into a child that carries the same
    # account_kind, so two accounts match the kind. Every read and write must
    # still resolve to the real (non-testing) operator account.
    it 'resolves the real operator account, never its testing child' do
      sign_in(operator)

      post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

      expect(response).to have_http_status(:redirect)

      testing_child = operator_account.testing_accounts.reload.sole

      expect(testing_child.testing?).to be(true)

      # Set-based, so the pin holds whichever row the database would hand a
      # bare LIMIT 1 first: both rows match the kind, only the parent is a
      # candidate.
      expect(Account.where(account_kind: Account::OPERATOR_KIND).pluck(:id))
        .to contain_exactly(operator_account.id, testing_child.id)
      expect(OperatorConfigs.candidates.pluck(:id)).to eq([operator_account.id])

      expect(OperatorConfigs.account).to eq(operator_account)
      expect(OperatorConfigs.enabled?(:fulltext_search)).to be(false)

      OperatorConfigs.set!(:fulltext_search, true)

      expect(OperatorConfigs.enabled?(:fulltext_search)).to be(true)
      expect(operator_account.account_configs.find_by!(key: 'fulltext_search').value).to be(true)
      expect(testing_child.account_configs.where(key: 'fulltext_search')).not_to exist
      expect(AccountConfig.where(key: 'fulltext_search').sole.account).to eq(operator_account)
    end
  end

  describe 'no HTTP path creates or promotes an operator' do
    it 'never mentions platform_operator in a controller' do
      hits = Rails.root.glob('app/controllers/**/*.rb').select do |path|
        File.read(path).include?('platform_operator')
      end

      expect(hits).to be_empty
    end

    it 'ignores platform_operator and unknown roles on an admin user update' do
      account = create(:account, :internal)
      admin = create(:user, :admin, account:)
      target = create(:user, :editor, account:)
      sign_in(admin)

      patch user_path(target), params: {
        user: { first_name: 'Promoted', platform_operator: true, role: 'superadmin' }
      }

      expect(response).to have_http_status(:redirect)
      expect(target.reload.first_name).to eq('Promoted')
      expect(target.platform_operator).to be(false)
      expect(target.role).to eq(User::EDITOR_ROLE)
    end

    it 'accepts only the existing roles on an invitation' do
      account = create(:account, :internal)
      sign_in(create(:user, :admin, account:))

      post users_path, params: {
        user: { email: 'golden-role-injection@example.com', first_name: 'Role', last_name: 'Probe',
                role: 'superadmin', platform_operator: true }
      }

      invited = User.find_by!(email: 'golden-role-injection@example.com')

      expect(invited.role).to eq(User::ADMIN_ROLE)
      expect(invited.platform_operator).to be(false)

      post users_path, params: {
        user: { email: 'golden-role-viewer@example.com', first_name: 'Role', last_name: 'Probe', role: 'viewer' }
      }

      expect(User.find_by!(email: 'golden-role-viewer@example.com').role).to eq(User::VIEWER_ROLE)
    end

    describe 'provisioning' do
      around do |example|
        original_token = ENV.fetch('ADMIN_PROVISION_TOKEN', nil)
        ENV['ADMIN_PROVISION_TOKEN'] = 'golden-operator-provision-token'

        example.run
      ensure
        if original_token.nil?
          ENV.delete('ADMIN_PROVISION_TOKEN')
        else
          ENV['ADMIN_PROVISION_TOKEN'] = original_token
        end
      end

      it 'ignores platform_operator, role and account_kind' do
        post '/api/admin/accounts',
             headers: { 'x-admin-token': 'golden-operator-provision-token', 'content-type': 'application/json' },
             params: {
               name: 'Provisioned Firm', email: 'golden-provisioned-operator@example.com',
               platform_operator: true, role: 'superadmin', account_kind: Account::OPERATOR_KIND,
               user: { platform_operator: true }
             }.to_json

        expect(response).to have_http_status(:created)

        user = User.find_by!(email: 'golden-provisioned-operator@example.com')

        expect(user.platform_operator).to be(false)
        expect(user.role).to eq(User::ADMIN_ROLE)
        expect(user.account.account_kind).to eq(Account::INTERNAL_KIND)
      end
    end

    describe 'operator:seed' do
      around do |example|
        Rails.application.load_tasks unless Rake::Task.task_defined?('operator:seed')
        original_email = ENV.fetch('OPERATOR_EMAIL', nil)
        original_password = ENV.fetch('OPERATOR_PASSWORD', nil)

        example.run
      ensure
        Rake::Task['operator:seed'].reenable

        if original_email.nil?
          ENV.delete('OPERATOR_EMAIL')
        else
          ENV['OPERATOR_EMAIL'] = original_email
        end

        if original_password.nil?
          ENV.delete('OPERATOR_PASSWORD')
        else
          ENV['OPERATOR_PASSWORD'] = original_password
        end
      end

      it 'refuses to run without OPERATOR_PASSWORD and never generates one' do
        ENV['OPERATOR_EMAIL'] = 'golden-operator@example.com'
        ENV.delete('OPERATOR_PASSWORD')

        expect do
          expect { Rake::Task['operator:seed'].invoke }.to raise_error(SystemExit)
        end.to output(/OPERATOR_PASSWORD is required/).to_stderr

        expect(Account.exists?(account_kind: Account::OPERATOR_KIND)).to be(false)
        expect(User.exists?(email: 'golden-operator@example.com')).to be(false)
      end
    end
  end
end
