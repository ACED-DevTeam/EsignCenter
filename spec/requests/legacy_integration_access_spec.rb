# frozen_string_literal: true

RSpec.describe 'Legacy integration access', type: :request do
  let(:account) { create(:account, :internal) }
  let(:robot) { create(:user, account:, role: 'integration') }
  let(:headers) { { 'X-Auth-Token' => robot.access_token.token } }

  it 'keeps API identity discovery and same-account template access' do
    template = create(:template, account:, author: robot, attachment_count: 0)

    get '/api/user', headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(robot.id)

    get "/api/templates/#{template.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(template.id)

    put "/api/templates/#{template.id}", headers: headers, params: { name: 'Robot updated document' }.to_json
    expect(response).to have_http_status(:ok)
    expect(template.reload.name).to eq('Robot updated document')
  end

  it 'refuses cross-account document access and reports the refused door' do
    other_account = create(:account, :internal)
    other_author = create(:user, account: other_account)
    template = create(:template, account: other_account, author: other_author, attachment_count: 0)
    allow(ErrorReport).to receive(:warning)

    get "/api/templates/#{template.id}", headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error']).to include('human account administrator')
    expect(ErrorReport).to have_received(:warning).with(
      'Legacy integration access refused', user_id: robot.id, account_id: account.id, door: 'api/templates#show'
    )
  end

  it 'keeps testing-account robots isolated even when a parent template is shared' do
    parent = create(:account, :internal, :with_testing_account)
    testing_robot = create(:user, account: parent.testing_accounts.first, role: 'integration')
    parent_author = create(:user, account: parent)
    template = create(:template, account: parent, author: parent_author, attachment_count: 0)
    TemplateSharing.create!(template:, account: testing_robot.account, ability: 'manage')
    testing_headers = { 'X-Auth-Token' => testing_robot.access_token.token }

    get '/api/templates', headers: testing_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['data']).to be_empty

    get "/api/templates/#{template.id}", headers: testing_headers
    expect(response).to have_http_status(:forbidden)
  end

  it 'cannot create a human administrator through an inherited session' do
    sign_in(robot)
    allow(ErrorReport).to receive(:warning)

    expect do
      post '/users', params: { user: { email: 'new-admin@example.com', role: User::ADMIN_ROLE } }
    end.not_to change(User, :count)

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to include('human account administrator')
    expect(ErrorReport).to have_received(:warning).with(
      'Legacy integration access refused', user_id: robot.id, account_id: account.id, door: 'users#create'
    )
  end

  it 'cannot change company settings through an inherited session' do
    sign_in(robot)

    expect do
      patch settings_account_path, params: { account: { name: 'Robot renamed company' } }
    end.not_to(change { account.reload.name })

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to include('human account administrator')
  end

  it 'continues to require the API plan entitlement' do
    account.update!(account_kind: Account::CUSTOMER_KIND)

    get '/api/templates', headers: headers

    expect(response).to have_http_status(:forbidden)
  end
end
