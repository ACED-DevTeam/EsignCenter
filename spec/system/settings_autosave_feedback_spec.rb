# frozen_string_literal: true

# Switches that save themselves on change (<submit-form data-on="change">) get
# a bare 200 back and no page, so the page has to say whether the change stuck:
# a notice when it did, and an error plus the switch put back when it did not.
RSpec.describe 'Settings that save on change' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  def toggle_for(key)
    find("form:has(input[name='account_config[key]'][value='#{key}']) input[type='checkbox']")
  end

  # Answers every save of an account setting from the browser, before it
  # reaches the app, the way a failing server or a dropped connection would.
  def intercept_account_config_saves(&)
    page.driver.browser.network.intercept
    page.driver.browser.on(:request) do |request|
      if request.url.end_with?('/account_configs')
        yield request
      else
        request.continue
      end
    end
  end

  before do
    sign_in(user)
  end

  describe 'on the account page' do
    before do
      visit settings_account_path
    end

    it 'says the setting was saved, then gets out of the way' do
      toggle_for(AccountConfig::FORCE_MFA).click

      expect(page).to have_css('#autosave_toast[role="status"]', text: 'Settings have been saved.')
      expect(AccountConfig.find_by(account:, key: AccountConfig::FORCE_MFA).value).to be(true)

      expect(page).to have_no_css('#autosave_toast')
    end

    it 'says so and puts the switch back when the server refuses the save' do
      intercept_account_config_saves do |request|
        request.respond(responseCode: 500, responseHeaders: { 'Content-Type' => 'text/html' },
                        body: '<html><body>Server error page</body></html>')
      end

      toggle_for(AccountConfig::FORCE_MFA).click

      expect(page).to have_css('#autosave_toast[role="alert"]',
                               text: 'Your change could not be saved. Please try again.')
      expect(page).to have_no_content('Server error page')
      expect(page).to have_current_path(settings_account_path)
      expect(toggle_for(AccountConfig::FORCE_MFA)).not_to be_checked
    end

    it 'says so and puts the switch back when the connection drops' do
      # Turbo re-throws the network error after handing it to the form, which
      # the default driver reports as a page error; the page itself copes.
      Capybara.register_driver(:headless_cuprite_network_errors) do |app|
        Capybara::Cuprite::Driver.new(app, window_size: [1200, 800], process_timeout: 20, timeout: 20,
                                           browser_options: { 'no-sandbox' => nil })
      end
      driven_by :headless_cuprite_network_errors
      sign_in(user)
      visit settings_account_path

      intercept_account_config_saves(&:abort)

      toggle_for(AccountConfig::WITH_SIGNATURE_ID).click

      expect(page).to have_css('#autosave_toast[role="alert"]',
                               text: 'Your change could not be saved. Please try again.')
      expect(toggle_for(AccountConfig::WITH_SIGNATURE_ID)).not_to be_checked
      expect(AccountConfig.find_by(account:, key: AccountConfig::WITH_SIGNATURE_ID)).to be_nil
    end

    it 'speaks the language of the account' do
      account.update!(locale: 'de-DE')
      visit settings_account_path

      toggle_for(AccountConfig::FORCE_MFA).click

      expect(page).to have_css('#autosave_toast', text: 'Die Einstellungen wurden gespeichert.')
    end
  end

  it 'confirms a personal setting on the notifications page' do
    visit settings_notifications_path

    find("form:has(input[name='user_config[key]']) input[type='checkbox']").click

    expect(page).to have_css('#autosave_toast', text: 'Settings have been saved.')
  end

  it 'shows the notice above a template modal' do
    template = create(:template, account:, author: user)

    visit template_path(template)
    click_on 'Link'

    within '#modal' do
      find('#template_shared_link').click
    end

    expect(page).to have_css('#autosave_toast', text: 'Settings have been saved.')
    expect(page).to have_css('#modal')
    expect(template.reload.shared_link).to be(true)
  end
end
