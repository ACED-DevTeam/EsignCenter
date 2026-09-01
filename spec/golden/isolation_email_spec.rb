# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Email tenant isolation', type: :lib do
  include_context 'with isolated SMTP environment'

  before do
    allow(Docuseal).to receive(:demo?).and_return(false)
  end

  def pin_smtp(account, host: 'pinned.smtp.example', username: 'pinned-user', from_email: 'tenant@example.com')
    create(
      :encrypted_config,
      account:,
      key: EncryptedConfig::EMAIL_SMTP_KEY,
      value: {
        'host' => host,
        'port' => '587',
        'username' => username,
        'password' => 'pinned-password',
        'from_email' => from_email,
        'authentication' => 'plain'
      }
    )
  end

  def build_message(account_id: nil)
    Mail.new(
      from: 'Original Sender <original@example.com>',
      to: 'recipient@example.com',
      subject: 'Test email',
      body: 'Hello'
    ).tap do |message|
      message.delivery_method(:test)
      message['X-EC-Account-Id'] = account_id.to_s if account_id
    end
  end

  it 'uses the sending account pin even when platform SMTP is configured' do
    account = create(:account, name: 'Pinned Tenant')
    pin_smtp(account, host: 'tenant.smtp.example', username: 'tenant-user', from_email: 'own@example.com')
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    ENV['SMTP_USERNAME'] = 'platform-user'
    ENV['SMTP_FROM'] = 'platform@example.com'
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
    message = build_message(account_id: account.id)

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method.settings).to include(address: 'tenant.smtp.example', user_name: 'tenant-user')
    expect(message.from).to eq(['own@example.com'])
    expect(message['X-EC-Account-Id']).to be_nil
  end

  it 'uses the platform SMTP default and Postmark token when the account has no pin' do
    account = create(:account)
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    ENV['SMTP_FROM'] = 'platform@example.com'
    ENV['POSTMARK_API_TOKEN'] = 'server-token'
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
    message = build_message(account_id: account.id)

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method.settings).to include(
      address: 'platform.smtp.example',
      user_name: 'server-token',
      password: 'server-token'
    )
    expect(message[:from].to_s).to include('Original Sender', 'platform@example.com')
    expect(message[:from].to_s).not_to include('original@example.com')
  end

  it 'never reads another account pin when the sending account has none' do
    pinned_account = create(:account)
    sending_account = create(:account)
    pin_smtp(pinned_account, host: 'other-tenant.smtp.example')
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
    allow(Rails.logger).to receive(:warn)
    message = build_message(account_id: sending_account.id)

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method).to be_a(Mail::TestMailer)
    expect(Rails.logger).to have_received(:warn)
      .with("no SMTP config for account #{sending_account.id}")
  end

  it 'uses platform SMTP for an untagged Devise-style message' do
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
    message = build_message

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method.settings[:address]).to eq('platform.smtp.example')
  end

  it 'leaves the delivery method unchanged in test mode and always strips the account tag' do
    message = build_message(account_id: create(:account).id)
    original_delivery_method = message.delivery_method
    allow(MailConfigs).to receive(:delivery_mode).and_return('test')

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method).to equal(original_delivery_method)
    expect(message['X-EC-Account-Id']).to be_nil
  end

  it 'tags SubmitterMailer and applies the submitter account pin' do
    account = create(:account, name: 'Submitter Tenant')
    author = create(:user, account:)
    template = create(:template, account:, author:, attachment_count: 0)
    submission = create(:submission, template:, created_by_user: author)
    submitter = create(:submitter, submission:, uuid: template.submitters.first['uuid'])
    pin_smtp(account, host: 'submitter.smtp.example')
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')

    message = SubmitterMailer.invitation_email(submitter).message
    expect(message['X-EC-Account-Id']&.value).to eq(account.id.to_s)

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method.settings[:address]).to eq('submitter.smtp.example')
    expect(message['X-EC-Account-Id']).to be_nil
  end

  it 'forces test delivery when a real SMTP transport is configured but the mode is not smtp' do
    message = build_message
    message.delivery_method(:smtp, address: 'platform.smtp.example', port: 587)
    allow(MailConfigs).to receive(:delivery_mode).and_return('test')

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method).to be_a(Mail::TestMailer)
  end

  it 'tags Devise mail with the user account so pinned SMTP applies' do
    account = create(:account, name: 'Devise Tenant')
    user = create(:user, account:)
    pin_smtp(account, host: 'devise.smtp.example')
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')

    message = Devise::Mailer.reset_password_instructions(user, 'token').message
    expect(message['X-EC-Account-Id']&.value).to eq(account.id.to_s)

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method.settings[:address]).to eq('devise.smtp.example')
    expect(message['X-EC-Account-Id']).to be_nil
  end

  it 'tags UserMailer with the invited user account' do
    account = create(:account)
    user = create(:user, account:)

    message = UserMailer.invitation_email(user).message

    expect(message['X-EC-Account-Id']&.value).to eq(account.id.to_s)
  end

  it 'tags SettingsMailer with the explicitly supplied account' do
    account = create(:account)

    message = SettingsMailer.smtp_successful_setup('sender@example.com', account).message

    expect(message['X-EC-Account-Id']&.value).to eq(account.id.to_s)
  end

  it 'uses the corrected esigncenter.com default From domain' do
    account = create(:account)
    user = create(:user, account:)

    message = UserMailer.invitation_email(user).message

    expect(message.from).to eq(['noreply@esigncenter.com'])
  end

  it 'reports email availability only for the account pin or platform environment' do
    pinned_account = create(:account)
    unpinned_account = create(:account)
    pin_smtp(pinned_account)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

    expect(Accounts.can_send_emails?(pinned_account)).to be(true)
    expect(Accounts.can_send_emails?(unpinned_account)).to be(false)

    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'

    expect(Accounts.can_send_emails?(unpinned_account)).to be(true)
  end
end
# rubocop:enable RSpec/DescribeClass
