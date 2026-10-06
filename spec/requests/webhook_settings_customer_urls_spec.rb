# frozen_string_literal: true

RSpec.describe 'Webhook settings URL validation', type: :request do
  it 'refuses an HTTP URL for a paid customer and shows the validation error' do
    account = create(:account, :paid)
    sign_in(create(:user, account:))

    expect do
      post '/settings/webhooks', params: {
        webhook_url: { url: 'http://example.com/webhook', events: ['submission.created'] }
      }
    end.not_to change(WebhookUrl, :count)

    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to eq('Webhook URL must use https')

    follow_redirect!

    expect(response.body).to include('Webhook URL must use https')
  end

  it 'allows an HTTP URL for an internal account' do
    account = create(:account, :internal)
    sign_in(create(:user, account:))

    expect do
      post '/settings/webhooks', params: {
        webhook_url: { url: 'http://localhost/webhook', events: ['submission.created'] }
      }
    end.to change(WebhookUrl, :count).by(1)

    expect(response).to have_http_status(:redirect)
    expect(WebhookUrl.last.url).to eq('http://localhost/webhook')
  end
end
