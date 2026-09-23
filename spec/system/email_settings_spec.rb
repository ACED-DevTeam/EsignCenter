# frozen_string_literal: true

RSpec.describe 'Email Settings' do
  include_context 'with isolated SMTP environment'

  let!(:account) { create(:account, :paid) }
  let!(:user) { create(:user, account:) }

  before do
    sign_in(user)
  end

  context 'when SMTP settings are not set' do
    it 'setup SMTP settings' do
      visit settings_email_index_path

      fill_in 'Host', with: 'smtp.example.com'
      fill_in 'Port', with: '587'
      fill_in 'Username', with: 'user@example.com'
      fill_in 'Password', with: 'password'
      fill_in 'Domain', with: 'example.com'
      fill_in 'Send from Email', with: 'user@example.com'
      select 'Plain', from: 'Authentication'
      choose 'TLS'

      expect do
        click_button 'Save'
      end.to change(EncryptedConfig, :count).by(1)

      encrypted_config = EncryptedConfig.find_by(account:, key: EncryptedConfig::EMAIL_SMTP_KEY)

      expect(encrypted_config.value['host']).to eq('smtp.example.com')
      expect(encrypted_config.value['port']).to eq('587')
      expect(encrypted_config.value['username']).to eq('user@example.com')
      expect(encrypted_config.value['password']).to eq('password')
      expect(encrypted_config.value['domain']).to eq('example.com')
      expect(encrypted_config.value['authentication']).to eq('plain')
      expect(encrypted_config.value['security']).to eq('tls')
      expect(encrypted_config.value['from_email']).to eq('user@example.com')
    end
  end

  context 'when SMTP settings are set' do
    let!(:encrypted_config) do
      create(:encrypted_config, account:, key: EncryptedConfig::EMAIL_SMTP_KEY, value: {
               host: 'smtp.example.com',
               port: '587',
               username: 'user@example.co',
               password: 'password',
               domain: 'example.com',
               authentication: 'plain',
               security: 'tls',
               from_email: 'user@example.co'
             })
    end

    before do
      visit settings_email_index_path
    end

    # Optional artifacts for the implementation/review run, using the same
    # isolated account and rendered state the assertions just inspected.
    def capture_smtp_evidence(viewport)
      return unless ENV['SMTP_SCREENSHOTS'] == 'true'

      # rubocop:disable Lint/Debugger
      page.save_screenshot(Rails.root.join("tmp/smtp-failure-#{viewport}.png"), full: true)
      # rubocop:enable Lint/Debugger
    end

    def record_failure
      create(:account_config, account:, key: AccountConfig::SMTP_FAILURE_KEY,
                              value: { 'failed_at' => Time.current.iso8601,
                                       'notified_at' => Time.current.iso8601,
                                       'reason' => 'The email server did not accept the sign-in details.' })
    end

    it 'shows the recent failure on desktop and phone widths' do
      page.driver.resize(1200, 800)
      record_failure
      visit settings_email_index_path

      expect(page).to have_content('Your email server could not send a message')
      expect(page).to have_content('The email server did not accept the sign-in details.')
      expect(page).to have_content('UTC')
      expect(page).to have_button('Remove SMTP settings')
      capture_smtp_evidence('desktop')
      page.driver.resize(390, 844)
      expect(page).to have_content('Your email server could not send a message')
      expect(page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')).to be(true)
      capture_smtp_evidence('phone')
    end

    it 'clears the failure after a successful setup test' do
      record_failure
      visit settings_email_index_path
      fill_in 'Password', with: 'password'
      click_button 'Save'

      expect(page).to have_content('Changes have been saved')
      expect(page).to have_no_content('Your email server could not send a message')
      expect(AccountSmtpFailures.recent(account)).to be_nil
    end

    it 'keeps the recorded failure when the setup test fails' do
      record_failure
      delivery = instance_double(ActionMailer::MessageDelivery)
      allow(SettingsMailer).to receive(:smtp_successful_setup).and_return(delivery)
      allow(delivery).to receive(:deliver_now!).and_raise(IOError, 'Connection failed')
      visit settings_email_index_path
      fill_in 'Password', with: 'password'
      click_button 'Save'

      expect(page).to have_content('Connection failed')
      expect(page).to have_content('Your email server could not send a message')
      expect(AccountSmtpFailures.recent(account)).to be_present
    end

    it 'removes the pin and clears the recorded failure' do
      record_failure
      visit settings_email_index_path
      accept_confirm { click_button 'Remove SMTP settings' }

      expect(page).to have_content('SMTP settings have been removed')
      expect(page).to have_no_content('Your email server could not send a message')
      expect(EncryptedConfig.exists?(encrypted_config.id)).to be(false)
      expect(AccountSmtpFailures.recent(account)).to be_nil
    end

    it 'shows pre-filled SMTP settings' do
      expect(page).to have_content('Email SMTP')
      expect(page).to have_field('Host', with: encrypted_config.value['host'])
      expect(page).to have_field('Port', with: encrypted_config.value['port'])
      expect(page).to have_field('Username', with: encrypted_config.value['username'])
      expect(page).to have_field('Domain', with: encrypted_config.value['domain'])
      expect(page).to have_select('Authentication', selected: 'Plain')
      expect(page).to have_field('Send from Email', with: encrypted_config.value['from_email'])
    end

    it 'updates SMTP settings' do
      fill_in 'Host', with: 'smtp.gmail.com'
      fill_in 'Port', with: '465'
      fill_in 'Username', with: 'user@gmail.com'
      fill_in 'Password', with: 'new_password'
      fill_in 'Domain', with: 'gmail.com'
      fill_in 'Send from Email', with: 'user@gmail.com'
      select 'Plain', from: 'Authentication'
      choose 'SSL'

      expect do
        click_button 'Save'
      end.not_to change(EncryptedConfig, :count)

      encrypted_config.reload

      expect(encrypted_config.value['host']).to eq('smtp.gmail.com')
      expect(encrypted_config.value['port']).to eq('465')
      expect(encrypted_config.value['username']).to eq('user@gmail.com')
      expect(encrypted_config.value['password']).to eq('new_password')
      expect(encrypted_config.value['domain']).to eq('gmail.com')
      expect(encrypted_config.value['authentication']).to eq('plain')
      expect(encrypted_config.value['security']).to eq('ssl')
      expect(encrypted_config.value['from_email']).to eq('user@gmail.com')
    end
  end
end
