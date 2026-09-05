# frozen_string_literal: true

RSpec.describe 'Sign Up' do
  stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET',
            clear: true

  before do
    # The instance is set up, so /sign_up is never the first-run setup redirect.
    create(:user)
    ENV['REGISTRATION_ENABLED'] = 'true'
    # Cloudflare's always-passing test site key: the widget renders without a real site.
    ENV['TURNSTILE_SITE_KEY'] = '1x00000000000000000000AA'
    ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
    ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'

    visit new_registration_path
  end

  # The "check your email" page is the last step of signing up, and it was the
  # one public page that scrolled sideways on a phone: the signed-out header
  # carried the wordmark, Sign In and a "Create free account" button, five
  # pixels more than a 390px screen holds. The page no longer offers a second
  # way to start something the reader has already started.
  it 'renders /sign_up/confirm without scrolling sideways on a phone' do
    page.driver.resize(390, 844)
    visit confirm_registration_path

    expect(page).to have_css('body')

    overflow = page.evaluate_script(<<~JS)
      (function () {
        var el = document.scrollingElement || document.documentElement;
        return el.scrollWidth - el.clientWidth;
      })()
    JS

    expect(overflow).to be <= 0, "/sign_up/confirm scrolls sideways by #{overflow}px at 390"
    expect(page).to have_no_link(href: registration_path)
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
    # The Google button carries the browser's timezone on its query string
    # (OmniAuth keeps only the authorize request's query for the callback).
    expect(page).to have_css('form#google_sign_in_form[action*="timezone="]')
    expect(page).to have_no_content('DocuSeal')
    expect(page).to have_no_content('Powered by')
  end

  # The sign-up page carries its own security policy (the Turnstile host);
  # a Turbo visit would keep the sign-in page's policy and the widget would
  # be refused. Both sign-up links are full page loads, and the proof is the
  # widget itself: Cloudflare's test key issues a token into the widget's
  # hidden field only when its script was allowed to load on the visited
  # page (the widget's own iframe sits in a closed shadow root, out of
  # CSS's reach).
  it 'loads the Turnstile widget when the sign-up page is reached from the sign-in page links' do
    visit new_user_session_path

    footer_link = find('a.link', text: /create free account/i)
    navbar_link = find('a.btn', text: /create free account/i)

    expect(footer_link['data-turbo']).to eq('false')
    expect(navbar_link['data-turbo']).to eq('false')

    footer_link.click

    expect(page).to have_current_path(new_registration_path)
    expect(page).to have_field('cf-turnstile-response', type: 'hidden', with: /\S/, wait: 15)

    visit new_user_session_path
    find('a.btn', text: /create free account/i).click

    expect(page).to have_current_path(new_registration_path)
    expect(page).to have_field('cf-turnstile-response', type: 'hidden', with: /\S/, wait: 15)
  end
end
