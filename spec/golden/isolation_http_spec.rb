# frozen_string_literal: true

RSpec.describe 'Cross-tenant HTTP denial', type: :request do
  let(:account_a) { create(:account, :paid) }
  let(:author_a) { create(:user, account: account_a) }
  let!(:template_a) { create(:template, account: account_a, author: author_a, name: 'Tenant A Confidential Packet') }
  let(:account_b) { create(:account, :paid) }
  let(:author_b) { create(:user, account: account_b) }
  let!(:template_b) { create(:template, account: account_b, author: author_b, name: 'Tenant B Own Packet') }
  let(:headers) { { 'x-auth-token': author_b.access_token.token } }

  # Config-level scoping is proven elsewhere; this is the HTTP boundary itself:
  # one tenant's API token can never read another tenant's template, while
  # the same token still serves its own.
  it 'refuses another tenant template over the templates API and serves the caller own' do
    get("/api/templates/#{template_a.id}", headers:)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq('error' => 'Not authorized')
    expect(response.body).not_to include('Tenant A Confidential Packet')

    get("/api/templates/#{template_b.id}", headers:)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(template_b.id)
    expect(response.parsed_body['name']).to eq('Tenant B Own Packet')
  end

  # The storage boundary: an EXPIRED download link is served only through
  # the presenting token's own ability, so the token is all that decides.
  # Tenant B's token gets a bare refusal — not one byte — of tenant A's
  # document, and its own document back in full.
  it 'refuses another tenant document over the blob proxy and serves the caller own' do
    blob_a = template_a.documents.first.blob
    blob_b = template_b.documents.first.blob

    get(ActiveStorage::Blob.proxy_path(blob_a, expires_at: 1.hour.ago), headers:)

    expect(response).to have_http_status(:forbidden)
    expect(response.body).to eq({ error: 'Not authorized' }.to_json)
    expect(response.headers['Content-Type']).not_to eq(blob_a.content_type)

    get(ActiveStorage::Blob.proxy_path(blob_b, expires_at: 1.hour.ago), headers:)

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(blob_b.byte_size)
  end
end
