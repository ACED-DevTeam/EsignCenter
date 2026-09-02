# frozen_string_literal: true

RSpec.describe 'Cross-tenant HTTP denial', type: :request do
  # Config-level scoping is proven elsewhere; this is the HTTP boundary itself:
  # one tenant's API token can never read another tenant's template, while
  # the same token still serves its own.
  it 'refuses another tenant template over the templates API and serves the caller own' do
    account_a = create(:account, :paid)
    author_a = create(:user, account: account_a)
    template_a = create(:template, account: account_a, author: author_a, name: 'Tenant A Confidential Packet')
    account_b = create(:account, :paid)
    author_b = create(:user, account: account_b)
    template_b = create(:template, account: account_b, author: author_b, name: 'Tenant B Own Packet')
    headers = { 'x-auth-token': author_b.access_token.token }

    get("/api/templates/#{template_a.id}", headers:)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq('error' => 'Not authorized')
    expect(response.body).not_to include('Tenant A Confidential Packet')

    get("/api/templates/#{template_b.id}", headers:)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(template_b.id)
    expect(response.parsed_body['name']).to eq('Tenant B Own Packet')
  end
end
