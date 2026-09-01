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

  it 'returns a conflict for a duplicate email and rolls back the account' do
    create(:user, email: 'golden-taken@example.com')
    original_counts = [Account.count, User.count, ProvisioningEvent.count]

    post_provision(name: 'Duplicate Firm', email: 'golden-taken@example.com')

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq('error' => 'A user with this email already exists')
    expect([Account.count, User.count, ProvisioningEvent.count]).to eq(original_counts)
  end

  it 'refuses test mode for a customer account without creating records' do
    account = create(:account)
    user = create(:user, account:)
    original_counts = [Account.count, User.count]
    sign_in(user)

    post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to eq('Test mode is unavailable for customer accounts')
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
    allow(Docuseal).to receive(:multitenant?).and_return(true)
    account = create(:account)
    admin = create(:user, account:)
    sign_in(admin)

    patch settings_account_path, params: {
      account: { name: 'Renamed Customer', account_kind: Account::INTERNAL_KIND }
    }

    expect(response).to have_http_status(:redirect)
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
    ENV.delete('OPERATOR_PASSWORD')

    expect do
      task.invoke
    end.to output(/Generated operator password: .+\nCreated operator account \d+\.\n/).to_stdout

    account = Account.find_by!(account_kind: Account::OPERATOR_KIND)
    user = account.users.find_by!(email: 'golden-operator@example.com')
    original_counts = [Account.count, User.count]

    expect(account.name).to eq('EsignCenter Operations')
    expect(user.platform_operator).to be(true)
    expect(user).to be_confirmed

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

  it 'redirects a customer away from setup once any user exists' do
    account = create(:account)
    create(:user, account:)

    expect { get setup_index_path }.not_to change(Account, :count)

    expect(response).to redirect_to(new_user_session_path)
  end
end
