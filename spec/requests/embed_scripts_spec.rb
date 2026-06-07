# frozen_string_literal: true

describe 'Embed scripts' do
  it 'serves the self-hosted signing form element' do
    get '/js/form.js'

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include('application/javascript')
    expect(response.body).to include("customElements.define('docuseal-form', DocusealForm)")
    expect(response.body).to include('document.createElement')
    expect(response.body).not_to include('Upgrade to Pro')
  end

  it 'keeps the builder placeholder until the embedded builder is implemented' do
    get '/js/builder.js'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('docuseal-builder')
    expect(response.body).to include('Upgrade to Pro')
  end
end
