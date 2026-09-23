# frozen_string_literal: true

# The switches that save themselves on change decide what to show from the
# answer alone (app/javascript/elements/submit_form.js): a bare 2xx with no
# redirect means "saved, say so here", a redirect means "the next page says
# it", anything else means "it did not stick, put the switch back". These are
# the endpoints that answer with a bare 2xx; each one must keep doing that.
describe 'Settings saved on change' do
  let(:account) { create(:account, :paid) }
  let(:admin) { create(:user, :admin, account:) }
  let(:template) { create(:template, account:, author: admin) }

  before { sign_in(admin) }

  def expect_bare_success
    expect(response).to have_http_status(:ok)
    expect(response.body).to be_empty
    expect(response.location).to be_nil
  end

  it 'answers an account setting with a bare 200' do
    post account_configs_path, params: { account_config: { key: AccountConfig::FORCE_MFA, value: '1' } }

    expect_bare_success
    expect(AccountConfig.find_by(account:, key: AccountConfig::FORCE_MFA).value).to be(true)
  end

  it 'answers a personal setting with a bare 200' do
    post user_configs_path, params: { user_config: { key: UserConfig::RECEIVE_COMPLETED_EMAIL, value: '0' } }

    expect_bare_success
    expect(UserConfig.find_by(user: admin, key: UserConfig::RECEIVE_COMPLETED_EMAIL).value).to be(false)
  end

  it 'answers a template preference with a bare 200' do
    post template_preferences_path(template), params: { template: { preferences: { submitters_order: 'preserved' } } }

    expect_bare_success
    expect(template.reload.preferences['submitters_order']).to eq('preserved')
  end

  it 'answers the share-link switch with a bare 200' do
    post template_share_link_path(template), params: { template: { shared_link: '1' } }

    expect_bare_success
    expect(template.reload.shared_link).to be(true)
  end

  it 'answers a webhook event switch with a bare 200' do
    webhook_url = create(:webhook_url, account:, events: [])

    put webhook_preference_path(webhook_url), params: { webhook_url: { events: { 'form.completed' => '1' } } }

    expect_bare_success
    expect(webhook_url.reload.events).to eq(['form.completed'])
  end

  # A refusal on the free plan is a redirect that carries its own alert, so
  # the switch page shows the reason instead of a generic "not saved".
  it 'answers a paid-only change on the free plan with a redirect, not a bare 200' do
    free_admin = create(:user, :admin, account: create(:account))
    webhook_url = create(:webhook_url, account: free_admin.account, events: [])
    sign_in(free_admin)

    put webhook_preference_path(webhook_url), params: { webhook_url: { events: { 'form.completed' => '1' } } },
                                              headers: { 'Referer' => settings_webhooks_url }

    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to be_present
    expect(webhook_url.reload.events).to eq([])
  end
end
