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
