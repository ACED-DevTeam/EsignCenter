# frozen_string_literal: true

RSpec.describe 'Account Settings' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  before do
    sign_in(user)
    visit settings_account_path
  end

  it 'shows pre-filled account settings page' do
    expect(page).to have_content('Account')
    expect(page).to have_field('Company name', with: account.name)
    expect(page).to have_field('Time zone', with: account.timezone)
    expect(page).to have_field('Language', with: account.locale)

    # The application URL comes from the environment only.
    expect(page).to have_no_field('App URL')
  end

  it 'updates the account settings' do
    fill_in 'Company name', with: 'New Company Name'
    select '(GMT+01:00) Berlin', from: 'Time zone'
    select 'Español', from: 'Language'

    click_button 'Update'

    account.reload

    expect(account.name).to eq('New Company Name')
    expect(account.timezone).to eq('Berlin')
    expect(account.locale).to eq('es-ES')
  end

  it 'changes the account language' do
    select 'Deutsch', from: 'Language'

    click_button 'Update'

    account.reload

    expect(account.locale).to eq('de-DE')
    expect(page).to have_content('Konto')
    expect(page).to have_field('Firmenname', with: account.name)
    expect(page).to have_field('Zeitzone', with: account.timezone)
    expect(page).to have_field('Sprache', with: account.locale)
    expect(page).to have_button('Aktualisieren')
  end

  # W3 (session 10 staging walk). Nothing on this page looked broken, and the
  # console said `SyntaxError: Failed to execute 'closest' on 'Element':
  # '<uuid>' is not a valid selector` on the way in: @github/catalyst's tag
  # observer reads every `data-target` on the page as
  # `custom-element.property` and hands the first half to `closest()` as a CSS
  # selector — and the delete-account modal button was naming its dialog with
  # a bare UUID there. Which threw only when the UUID happened to start with a
  # digit, so the error came and went between page loads.
  #
  # Hence the assertion is on the ATTRIBUTE and not on the luck of one id:
  # nothing on this page may put anything but `element.property` in a
  # `data-target`. (Cuprite fails any example outright on an uncaught page
  # error, so the console is watched by the whole file already — this is what
  # makes the check deterministic.)
  describe 'the attributes a third-party library reads' do
    # `data-target` values Catalyst cannot parse: everything that is not
    # `custom-element.property`.
    def malformed_targets
      page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll('[data-target]'))
             .map((el) => el.getAttribute('data-target'))
             .filter((value) => !/^[a-zA-Z][\\w-]*\\.[a-zA-Z]/.test(value))
      JS
    end

    it 'names the delete-account modal without writing a bare id into data-target' do
      expect(malformed_targets).to eq([])
      expect(page).to have_css('[data-delete-account-button]')

      # And again the way the walk arrived — a Turbo navigation, which is when
      # the tag observer scans what has just been put on the page.
      visit settings_profile_index_path
      within('#account_settings_menu') { click_link 'Account' }

      expect(page).to have_css('[data-delete-account-button]')
      expect(malformed_targets).to eq([])

      # The modal still opens: the button reads the dialog's id from its own
      # attribute rather than one a third-party library also claims.
      find('[data-delete-account-button]').click

      expect(page).to have_css('[data-delete-account-modal]', visible: :visible)
    end
  end
end
