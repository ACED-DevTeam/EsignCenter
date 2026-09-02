# frozen_string_literal: true

RSpec.describe 'Sign Up' do
  stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'GOOGLE_OAUTH_CLIENT_ID', clear: true

  before do
    # The instance is set up, so /sign_up is never the first-run setup redirect.
    create(:user)
    ENV['REGISTRATION_ENABLED'] = 'true'
    # Cloudflare's always-passing test site key: the widget renders without a real site.
    ENV['TURNSTILE_SITE_KEY'] = '1x00000000000000000000AA'
    ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'

    visit new_registration_path
  end

  it 'renders the sign-up form with the Google button and no upstream attribution' do
    expect(page).to have_content('Create your free account')
    expect(page).to have_content('Free: 5 completed documents a month, 1 user.')

    ['Full name', 'Email', 'Password'].each do |field|
      expect(page).to have_field(field)
    end

    expect(page).to have_css('.cf-turnstile[data-sitekey="1x00000000000000000000AA"]')
    expect(page).to have_button('Continue with Google')
    expect(page).to have_button('Create free account')
    expect(page).to have_link('Terms of Service', href: '/terms')
    expect(page).to have_link('Privacy Policy', href: '/privacy')
    expect(page).to have_link('Already have an account?', href: new_user_session_path)
    expect(page).to have_field('user[timezone]', type: 'hidden', with: /\S/)
    expect(page).to have_no_content('DocuSeal')
    expect(page).to have_no_content('Powered by')
  end
end
