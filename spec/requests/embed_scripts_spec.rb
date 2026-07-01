# frozen_string_literal: true

describe 'Embed scripts' do
  it 'serves the self-hosted signing form element' do
    get '/js/form.js'

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include('application/javascript')
    expect(response.body).to include("customElements.define('esigncenter-form', EsigncenterForm)")
    expect(response.body).to include('document.createElement')
    expect(response.body).not_to include('Upgrade to Pro')
  end

  it 'serves the self-hosted template builder element' do
    get '/js/builder.js'

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include('application/javascript')
    expect(response.body).to include("customElements.define('esigncenter-builder', EsigncenterBuilder)")
    expect(response.body).to include('esigncenter-builder')
    expect(response.body).to include('document.createElement')
    expect(response.body).not_to include('Upgrade to Pro')
  end

  it 'does not serve an embed script for unknown filenames' do
    get '/js/unknown.js'

    expect(response).to have_http_status(:not_found)
  end
end
