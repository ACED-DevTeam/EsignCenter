# frozen_string_literal: true

# The one-time "What's your name?" page in a real browser: an account still
# named after its owner's email address is asked once, on the way to the
# dashboard, and the answer is what signers see from then on.
RSpec.describe 'Name prompt' do
  let(:email) { 'x7k2q9@privaterelay.appleid.com' }
  let(:account) { create(:account, name: email) }
  let!(:user) { create(:user, account:, email:, first_name: nil, last_name: nil) }

  before do
    FileUtils.mkdir_p(screenshot_dir)
    sign_in(user)
  end

  def screenshot_dir
    Rails.root.join('tmp/screenshots')
  end

  it 'asks once on the way to the dashboard and then gets out of the way' do
    visit root_path

    expect(page).to have_current_path(name_prompt_path)
    expect(page).to have_content("What's your name?")
    expect(page).to have_css('[data-name-prompt-example]', text: 'sent you')

    fill_in 'Full name', with: 'Jane Smith'
    click_button 'Save'

    expect(page).to have_content('Thanks. Signers will now see your name.')
    expect(page).to have_current_path(root_path)
    expect(account.reload.name).to eq('Jane Smith')

    visit root_path

    expect(page).to have_no_content("What's your name?")
  end

  it 'says what is wrong when the answer is another email address' do
    visit name_prompt_path

    fill_in 'Full name', with: 'jane@example.com'
    click_button 'Save'

    expect(page).to have_content('Enter your name, not an email address.')
    expect(page).to have_css('#name[aria-invalid="true"]')
    expect(account.reload.name).to eq(email)
  end

  it 'renders at phone and desktop widths without sideways scrolling' do
    { 390 => 844, 1440 => 900 }.each do |width, height|
      page.driver.resize(width, height)

      visit name_prompt_path

      expect(page).to have_css('[data-name-prompt]')
      expect(page.evaluate_script('document.documentElement.scrollWidth <= document.documentElement.clientWidth'))
        .to be(true), "the name prompt scrolls sideways at #{width}px"

      page.driver.browser.screenshot(path: screenshot_dir.join("name-prompt-#{width}.png").to_s, full: true)

      fill_in 'Full name', with: 'jane@example.com'
      click_button 'Save'

      expect(page).to have_content('Enter your name, not an email address.')

      page.driver.browser.screenshot(path: screenshot_dir.join("name-prompt-error-#{width}.png").to_s, full: true)
    end
  end
end
