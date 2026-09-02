# frozen_string_literal: true

require 'rake'

RSpec.describe 'Account and user creation matrix', type: :request do
  let(:admin_token) { 'golden-provision-token' }
  let(:provision_headers) do
    { 'x-admin-token': admin_token, 'content-type': 'application/json' }
  end

  around do |example|
    original_token = ENV.fetch('ADMIN_PROVISION_TOKEN', nil)
    ENV['ADMIN_PROVISION_TOKEN'] = admin_token
    ActionMailer::Base.deliveries.clear

    example.run
  ensure
    if original_token.nil?
      ENV.delete('ADMIN_PROVISION_TOKEN')
    else
      ENV['ADMIN_PROVISION_TOKEN'] = original_token
    end
  end

  def post_provision(params)
    post '/api/admin/accounts', headers: provision_headers, params: params.to_json
  end

  it 'provisions an internal account with a confirmed user and audit event' do
    expect do
      post_provision(name: 'Provisioned Firm', email: 'golden-provisioned@example.com')
    end.to change(Account, :count).by(1)
      .and change(User, :count).by(1)
      .and change(ProvisioningEvent, :count).by(1)

    expect(response).to have_http_status(:created)

    event = ProvisioningEvent.last
    account = event.account
    user = account.users.find_by!(email: event.email)

    expect(account.account_kind).to eq(Account::INTERNAL_KIND)
    expect(user).to be_confirmed
    expect(event.email).to eq('golden-provisioned@example.com')
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it 'replays a provisioning response without creating duplicate records' do
    params = {
      name: 'Replay Firm',
      email: 'golden-replay@example.com',
      idempotency_key: 'golden-replay-key'
    }

    post_provision(params)
    first_body = response.parsed_body
    original_counts = [
      Account.count,
      User.count,
      AccessToken.count,
      AccountConfig.count,
      EncryptedConfig.count,
      WebhookUrl.count,
      ProvisioningEvent.count
    ]

    post_provision(params)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['account_id']).to eq(first_body['account_id'])
    expect(response.parsed_body['api_token']).to eq(first_body['api_token'])
    expect(
      [Account.count, User.count, AccessToken.count, AccountConfig.count, EncryptedConfig.count,
       WebhookUrl.count, ProvisioningEvent.count]
    ).to eq(original_counts)
  end

  it 'returns a conflict when an idempotency key is replayed with different parameters' do
    post_provision(name: 'Replay Firm', email: 'golden-replay-a@example.com', idempotency_key: 'golden-mismatch-key')
    original_counts = [Account.count, User.count, ProvisioningEvent.count]

    post_provision(name: 'Replay Firm', email: 'golden-replay-b@example.com', idempotency_key: 'golden-mismatch-key')

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['error']).to eq('Idempotency key was already used with different parameters')
    expect([Account.count, User.count, ProvisioningEvent.count]).to eq(original_counts)
  end

  it 'returns an unprocessable entity for a duplicate email and rolls back the account' do
    create(:user, email: 'golden-taken@example.com')
    original_counts = [Account.count, User.count, ProvisioningEvent.count]

    post_provision(name: 'Duplicate Firm', email: 'golden-taken@example.com')

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq('error' => 'Email has already been taken')
    expect([Account.count, User.count, ProvisioningEvent.count]).to eq(original_counts)
  end

  it 'refuses test mode for a customer account without creating records' do
    account = create(:account)
    user = create(:user, account:)
    original_counts = [Account.count, User.count]
    sign_in(user)

    post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to eq(I18n.t('test_mode_is_not_available_on_this_account'))
    expect(flash[:alert]).to eq('Test mode is not available on this account')
    expect([Account.count, User.count]).to eq(original_counts)
    expect(account.testing_accounts).to be_empty
  end

  it 'creates a confirmed internal test-mode user for an internal account' do
    account = create(:account, :internal)
    user = create(:user, account:)
    sign_in(user)

    expect do
      post testing_account_path, headers: { 'HTTP_REFERER' => root_url }
    end.to change(Account, :count).by(1).and change(User, :count).by(1)

    testing_account = account.testing_accounts.reload.first!
    testing_user = testing_account.users.first!

    expect(response).to have_http_status(:redirect)
    expect(testing_account.account_kind).to eq(Account::INTERNAL_KIND)
    expect(testing_user).to be_confirmed
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it 'forbids customer test-template sharing without creating a test account' do
    account = create(:account)
    user = create(:user, account:)
    template = create(:template, account:, author: user, attachment_count: 0)
    original_counts = [Account.count, User.count, TemplateSharing.count]
    sign_in(user)

    post template_sharings_testing_index_path,
         params: { template_id: template.id, value: '1' },
         as: :json

    expect(response).to have_http_status(:forbidden)
    expect([Account.count, User.count, TemplateSharing.count]).to eq(original_counts)
  end

  it 'hides the test-mode control from customer account pages' do
    account = create(:account)
    user = create(:user, account:)
    sign_in(user)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('testing_toggle')
  end

  it 'shows the test-mode control to internal account pages' do
    account = create(:account, :internal)
    user = create(:user, account:)
    sign_in(user)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('testing_toggle')
  end

  it 'does not permit platform-operator privilege through invitations' do
    account = create(:account)
    admin = create(:user, account:)
    sign_in(admin)

    post users_path, params: {
      user: {
        email: 'golden-invited-injection@example.com',
        first_name: 'Invited',
        last_name: 'User',
        platform_operator: true
      }
    }

    invited_user = User.find_by!(email: 'golden-invited-injection@example.com')

    expect(response).to have_http_status(:redirect)
    expect(invited_user.platform_operator).to be(false)
  end

  it 'does not permit account kind changes through account settings' do
    account = create(:account)
    admin = create(:user, account:)
    sign_in(admin)

    expect do
      patch settings_account_path, params: {
        account: { name: 'Renamed Customer', account_kind: Account::INTERNAL_KIND }
      }
    end.not_to change(Account, :count)

    # The rename itself is the happy path for every account kind; the point is
    # that account_kind is never assignable.
    expect(response).to redirect_to(settings_account_path)
    expect(account.reload.name).to eq('Renamed Customer')
    expect(account.account_kind).to eq(Account::CUSTOMER_KIND)
  end

  it 'confirms an invited user, sends the invitation, and sends no Devise confirmation', sidekiq: :inline do
    account = create(:account, :internal)
    admin = create(:user, account:)
    sign_in(admin)

    expect do
      post users_path, params: {
        user: {
          email: 'golden-invited@example.com',
          first_name: 'Golden',
          last_name: 'Invite'
        }
      }
    end.to change(ActionMailer::Base.deliveries, :count).by(1)

    invited_user = User.find_by!(email: 'golden-invited@example.com')
    delivery = ActionMailer::Base.deliveries.sole

    expect(invited_user).to be_confirmed
    expect(delivery.to).to eq(['golden-invited@example.com'])
    expect(delivery.subject).to eq("You are invited to #{Docuseal.product_name}")
  end

  it 'seeds one confirmed platform operator and is a no-op on a second invocation' do
    Rails.application.load_tasks unless Rake::Task.task_defined?('operator:seed')
    task = Rake::Task['operator:seed']
    original_email = ENV.fetch('OPERATOR_EMAIL', nil)
    original_password = ENV.fetch('OPERATOR_PASSWORD', nil)
    ENV['OPERATOR_EMAIL'] = 'golden-operator@example.com'
    ENV['OPERATOR_PASSWORD'] = 'golden-operator-password'

    # The password comes from the environment and is never echoed back.
    expect do
      task.invoke
    end.to output(/\ACreated operator account \d+\.\n\z/).to_stdout

    account = Account.find_by!(account_kind: Account::OPERATOR_KIND)
    user = account.users.find_by!(email: 'golden-operator@example.com')
    original_counts = [Account.count, User.count]

    expect(account.name).to eq('EsignCenter Operations')
    expect(user.platform_operator).to be(true)
    expect(user).to be_confirmed
    expect(user.valid_password?('golden-operator-password')).to be(true)

    task.reenable

    expect do
      task.invoke
    end.to output("An operator account already exists; no changes made.\n").to_stdout
    expect([Account.count, User.count]).to eq(original_counts)
  ensure
    task&.reenable

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

  # Before Session 2 the fulltext flag was a global row on the lowest-id
  # account; reads are now scoped to the operator account, which only exists
  # once the seed has run. The seed adopts the legacy flag so an upgrade does
  # not silently switch search off — and leaves the legacy row alone.
  describe 'operator:seed legacy fulltext flag adoption' do
    stash_env('OPERATOR_EMAIL', 'OPERATOR_PASSWORD')

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('operator:seed')
      ENV['OPERATOR_EMAIL'] = 'golden-operator@example.com'
      ENV['OPERATOR_PASSWORD'] = 'golden-operator-password'
    end

    after do
      Rake::Task['operator:seed'].reenable
      Docuseal.refresh_fulltext_search!
    end

    let(:task) { Rake::Task['operator:seed'] }

    it 'adopts a legacy flag from an internal account, leaves that row alone, and is idempotent' do
      legacy_account = create(:account, :internal)
      legacy_row = create(:account_config, account: legacy_account, key: 'fulltext_search', value: true)

      expect(Docuseal.fulltext_search?).to be(false)

      expect do
        task.invoke
      end.to output(
        /\ACreated operator account \d+\.\nfulltext search flag adopted from legacy account #{legacy_account.id}\n\z/
      ).to_stdout

      operator_account = Account.find_by!(account_kind: Account::OPERATOR_KIND)

      expect(operator_account.account_configs.find_by!(key: 'fulltext_search').value).to be(true)
      expect(legacy_row.reload.account).to eq(legacy_account)
      expect(legacy_row.value).to be(true)
      expect(AccountConfig.where(key: 'fulltext_search').count).to eq(2)
      expect(Docuseal.fulltext_search?).to be(true)

      task.reenable

      expect do
        task.invoke
      end.to output("An operator account already exists; no changes made.\n").to_stdout

      expect(AccountConfig.where(key: 'fulltext_search').count).to eq(2)
      expect(operator_account.account_configs.where(key: 'fulltext_search').sole.value).to be(true)
    end

    it 'adopts over an operator row that reads false' do
      operator_account = create(:account, :operator)
      create(:account_config, account: operator_account, key: 'fulltext_search', value: false)
      legacy_account = create(:account, :internal)
      create(:account_config, account: legacy_account, key: 'fulltext_search', value: true)

      expect do
        task.invoke
      end.to output("fulltext search flag adopted from legacy account #{legacy_account.id}\n").to_stdout

      expect(operator_account.account_configs.where(key: 'fulltext_search').sole.value).to be(true)
      expect(Docuseal.fulltext_search?).to be(true)
    end

    it 'creates no operator row when there is no legacy flag to adopt' do
      create(:account, :internal)

      expect do
        task.invoke
      end.to output(/\ACreated operator account \d+\.\n\z/).to_stdout

      operator_account = Account.find_by!(account_kind: Account::OPERATOR_KIND)

      expect(operator_account.account_configs.where(key: 'fulltext_search')).not_to exist
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
      expect(Docuseal.fulltext_search?).to be(false)
    end

    it 'ignores a flag that sits only on a testing child' do
      parent = create(:account, :internal, :with_testing_account)
      testing_child = parent.testing_accounts.sole
      create(:account_config, account: testing_child, key: 'fulltext_search', value: true)

      expect do
        task.invoke
      end.to output(/\ACreated operator account \d+\.\n\z/).to_stdout

      operator_account = Account.find_by!(account_kind: Account::OPERATOR_KIND)

      expect(operator_account.account_configs.where(key: 'fulltext_search')).not_to exist
      expect(AccountConfig.where(key: 'fulltext_search').sole.account).to eq(testing_child)
    end
  end

  it 'redirects a customer away from setup once any user exists' do
    account = create(:account)
    create(:user, account:)

    expect { get setup_index_path }.not_to change(Account, :count)

    expect(response).to redirect_to(new_user_session_path)
  end

  it 'refuses a setup POST once any user exists, creating no account or user' do
    create(:user, account: create(:account))

    setup_params = {
      account: { name: 'Setup Squatter', timezone: 'UTC', locale: 'en-US' },
      user: {
        first_name: 'Setup',
        last_name: 'Squatter',
        email: 'golden-setup-squatter@example.com',
        password: 'golden-setup-password'
      },
      encrypted_config: { value: 'https://squatter.example.test' }
    }

    original_counts = [Account.count, User.count]

    post setup_index_path, params: setup_params

    expect(response).to redirect_to(new_user_session_path)
    expect([Account.count, User.count]).to eq(original_counts)
    expect(User.exists?(email: 'golden-setup-squatter@example.com')).to be(false)
  end

  # Self-serve signup is off: Devise is mounted without :registrations, so no
  # registration route may exist. Re-adding :registrations fails here.
  it 'exposes no Devise registration route' do
    route_names = Rails.application.routes.routes.filter_map(&:name)

    expect(route_names.grep(/registration/)).to be_empty
    expect(User.devise_modules).not_to include(:registerable)
    expect(Rails.application.routes.url_helpers).not_to respond_to(:new_user_registration_path)
  end

  # Devise :confirmations is mounted (a confirmed_at is required to sign in),
  # but its public endpoints are a registration surface: the resend form
  # enumerates emails and the POST triggers mail to any address. They sit
  # behind the REGISTRATION_ENABLED kill switch until self-serve signup ships.
  describe 'Devise confirmation routes behind REGISTRATION_ENABLED' do
    around do |example|
      original_value = ENV.fetch('REGISTRATION_ENABLED', nil)
      ENV.delete('REGISTRATION_ENABLED')

      example.run
    ensure
      if original_value.nil?
        ENV.delete('REGISTRATION_ENABLED')
      else
        ENV['REGISTRATION_ENABLED'] = original_value
      end
    end

    it 'returns 404 for the resend form and the resend POST while the switch is off' do
      user = create(:user, email: 'golden-unconfirmed@example.com')
      user.update_column(:confirmed_at, nil)

      get new_user_confirmation_path

      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty

      expect do
        post user_confirmation_path, params: { user: { email: 'golden-unconfirmed@example.com' } }
      end.not_to change(ActionMailer::Base.deliveries, :count)

      expect(response).to have_http_status(:not_found)
      expect(user.reload.confirmation_sent_at).to be_nil
    end

    it 'serves the resend form and sends confirmation mail once the switch is on' do
      ENV['REGISTRATION_ENABLED'] = 'true'
      user = create(:user, email: 'golden-unconfirmed@example.com')
      user.update_column(:confirmed_at, nil)

      get new_user_confirmation_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="user[email]"')

      expect do
        post user_confirmation_path, params: { user: { email: 'golden-unconfirmed@example.com' } }
      end.to change(ActionMailer::Base.deliveries, :count).by(1)

      expect(response).to have_http_status(:redirect)
      expect(ActionMailer::Base.deliveries.last.to).to eq(['golden-unconfirmed@example.com'])
      expect(user.reload.confirmation_sent_at).to be_present
    end
  end
end
