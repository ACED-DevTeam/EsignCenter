# frozen_string_literal: true

RSpec.describe 'Shared form email verification notice', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user, shared_link: true) }

  it 'explains that an emailed invitation is required when email 2FA is enabled' do
    template.update_column(:preferences, { 'require_email_2fa' => true })

    get "/d/#{template.slug}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Email invitation required')
    expect(response.body).to include(
      'This form requires an emailed invitation because email verification is enabled.'
    )
    expect(response.body).to include('The sender can turn off &quot;Require email 2FA&quot;')
  end

  context 'when the template is not shared' do
    let(:template) { create(:template, account:, author: user, shared_link: false) }

    before { template.update_column(:preferences, { 'require_email_2fa' => true }) }

    # The notice is only for shared templates: a private one must not confirm
    # it exists (or name itself) to a stranger.
    it 'is a 404 for an anonymous visitor' do
      expect { get "/d/#{template.slug}" }.to raise_error(ActionController::RoutingError)
    end

    it 'shows the owner the private page, not the verification notice' do
      sign_in(user)

      get "/d/#{template.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('share_link_is_currently_disabled'))
      expect(response.body).not_to include('Email invitation required')
    end
  end

  it 'still renders the normal shared form when email 2FA is disabled' do
    get "/d/#{template.slug}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="submitter[email]"')
    expect(response.body).not_to include('Email invitation required')
  end
end
