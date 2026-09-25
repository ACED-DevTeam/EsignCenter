# frozen_string_literal: true

require 'rake'

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
    account = create(:account, :paid, name: 'Pinned Tenant')
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
    pinned_account = create(:account, :paid)
    sending_account = create(:account, :paid)
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
    message['X-EC-Mail-Route'] = 'platform'
    original_delivery_method = message.delivery_method
    allow(MailConfigs).to receive(:delivery_mode).and_return('test')

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method).to equal(original_delivery_method)
    expect(message['X-EC-Mail-Route']).to be_nil
    expect(message['X-EC-Account-Id']).to be_nil
  end

  it 'tags SubmitterMailer and applies the submitter account pin' do
    account = create(:account, :paid, name: 'Submitter Tenant')
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

  it 'keeps Devise password recovery on the platform server despite the account pin' do
    account = create(:account, :paid, name: 'Devise Tenant')
    user = create(:user, account:)
    pin_smtp(account, host: 'devise.smtp.example')
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    ENV['SMTP_FROM'] = 'platform@example.com'
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')

    message = Devise::Mailer.reset_password_instructions(user, 'token').message
    expect(message['X-EC-Account-Id']&.value).to eq(account.id.to_s)

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method.settings[:address]).to eq('platform.smtp.example')
    expect(message.from).to eq(['platform@example.com'])
    expect(message['X-EC-Mail-Route']).to be_nil
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

  it 'routes every platform-notice mailer through the platform with its own From' do
    account = create(:account, :paid)
    user = create(:user, account:)
    invite = create(:account_invite, account:)
    pin_smtp(account)
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    ENV['SMTP_FROM'] = 'EsignCenter <platform@example.com>'
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')

    deliveries = [
      BillingMailer.suspended(account), QuotaMailer.storage_warning(account),
      AccountMailer.deletion_cancelled_to(account, user.email),
      AccountInviteMailer.invitation(invite, invite.raw_token), UserMailer.invitation_email(user),
      SupportMailer.request_received(name: 'Owner', email: user.email, topic: 'other',
                                     topic_label: 'Other', message: 'Help', ip: '127.0.0.1'),
      OperatorMailer.alert('Alert', 'Body')
    ]
    deliveries.each do |delivery|
      message = delivery.message
      expect(message['X-EC-Mail-Route']&.value).to eq('platform')
      # Support/operator notices currently carry no account, but must stay on
      # the platform even if a caller starts tagging them in future.
      message['X-EC-Account-Id'] = account.id.to_s unless message['X-EC-Account-Id']
      2.times { ActionMailerConfigsInterceptor.delivering_email(message) }

      expect(message.delivery_method.settings[:address]).to eq('platform.smtp.example')
      expect(message.from).to eq(['platform@example.com'])
      expect(message['X-EC-Account-Id']).to be_nil
      expect(message['X-EC-Mail-Route']).to be_nil
    end
  end

  # Platform notices leave from noreply@, so a reply to a bill, a quota
  # warning, a deletion or dormancy notice or an invitation has to reach a
  # person: Reply-To is the support address. The customer's own mail to their
  # signers is NOT a platform notice and keeps its own rule
  # (Submitters::ReplyTo): the sender's address, or nothing — never ours.
  it 'puts the support address on Reply-To for platform notices, and only for them' do
    account = create(:account, :paid)
    user = create(:user, account:)
    invite = create(:account_invite, account:)
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    ENV['SMTP_FROM'] = 'EsignCenter <platform@example.com>'
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')

    platform = [
      BillingMailer.payment_failed(account, day: 1), BillingMailer.suspended(account),
      QuotaMailer.storage_warning(account), QuotaMailer.completions_warning(account),
      AccountMailer.deletion_cancelled_to(account, user.email),
      AccountMailer.dormant_warning_to(account, user.email, days_left: 30, purge_at: 30.days.from_now),
      AccountMailer.deletion_code(user, code: '123456'),
      AccountInviteMailer.invitation(invite, invite.raw_token), UserMailer.invitation_email(user)
    ]
    platform.each do |delivery|
      message = delivery.message
      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.from).to eq(['platform@example.com'])
      expect(message.reply_to).to eq([Docuseal::SUPPORT_EMAIL]), "#{message.subject} has no support Reply-To"
    end

    # The support form's own notice answers the requester, as it always has.
    support = SupportMailer.request_received(name: 'Owner', email: 'owner@example.com', topic: 'other',
                                             topic_label: 'Other', message: 'Help', ip: '127.0.0.1').message
    expect(support.reply_to).to eq(['owner@example.com'])

    # The SMTP test is sent from the customer's own address and server.
    expect(SettingsMailer.smtp_successful_setup('owner@example.com', account).message.reply_to).to be_nil
  end

  it 'leaves signer mail with the sender as Reply-To, never the platform support address' do
    account = create(:account, :paid)
    author = create(:user, account:, email: 'sender@acme.example')
    template = create(:template, account:, author:)
    submission = create(:submission, template:, created_by_user: author)
    submitter = create(:submitter, submission:, uuid: template.submitters.first['uuid'],
                                   email: 'signer@example.com')

    message = SubmitterMailer.invitation_email(submitter).message

    expect(message.reply_to).to eq(['sender@acme.example'])
    expect(message.reply_to).not_to include(Docuseal::SUPPORT_EMAIL)

    # Signing your own document: nobody new to reply to, so no Reply-To at all.
    submitter.update!(email: author.email)

    expect(SubmitterMailer.invitation_email(submitter.reload).message.reply_to).to be_nil
  end

  it 'keeps the SMTP setup test on the pin and explicitly excludes failure monitoring' do
    account = create(:account, :paid)
    pin_smtp(account)
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
    message = SettingsMailer.smtp_successful_setup('owner@example.com', account).message

    expect(message['X-EC-Mail-Route']&.value).to eq('smtp-test')
    2.times { ActionMailerConfigsInterceptor.delivering_email(message) }

    expect(message.delivery_method).to be_instance_of(Mail::SMTP)
    expect(message.delivery_method.settings[:address]).to eq('pinned.smtp.example')
    expect(message.from).to eq(['tenant@example.com'])
    expect(message['X-EC-Mail-Route']).to be_nil
  end

  it 'drops a platform notice with no platform server instead of using the pin' do
    account = create(:account, :paid)
    user = create(:user, account:)
    pin_smtp(account)
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
    message = UserMailer.invitation_email(user).message

    ActionMailerConfigsInterceptor.delivering_email(message)

    expect(message.delivery_method).to be_a(Mail::TestMailer)
    expect(message['X-EC-Mail-Route']).to be_nil
  end

  it 'keeps shared-link verification and the sender completed notification on the pin' do
    account = create(:account, :paid)
    author = create(:user, account:)
    template = create(:template, account:, author:, attachment_count: 0,
                                 preferences: { completed_notification_email_attach_documents: false,
                                                completed_notification_email_attach_audit: false })
    submission = create(:submission, template:, created_by_user: author)
    submitter = create(:submitter, submission:, uuid: template.submitters.first['uuid'])
    pin_smtp(account)
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
    allow(Submissions::EnsureResultGenerated).to receive(:call)

    [TemplateMailer.otp_verification_email(template, email: 'signer@example.com'),
     SubmitterMailer.completed_email(submitter, author)].each do |delivery|
      message = delivery.message
      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(AccountSmtpDelivery)
      expect(message.delivery_method.settings[:address]).to eq('pinned.smtp.example')
      expect(message.from).to eq(['tenant@example.com'])
    end
  end

  it 'uses the corrected esigncenter.com default From domain' do
    account = create(:account)
    user = create(:user, account:)

    message = UserMailer.invitation_email(user).message

    expect(message.from).to eq(['noreply@esigncenter.com'])
  end

  describe 'rake email pin management' do
    let(:pin_env_keys) { %w[ACCOUNT_ID SMTP_TOKEN_ENV GOLDEN_PIN_TOKEN FROM_EMAIL SMTP_HOST SMTP_PIN_PORT] }

    around do |example|
      original_values = pin_env_keys.index_with { |key| ENV.fetch(key, nil) }
      pin_env_keys.each { |key| ENV.delete(key) }

      example.run
    ensure
      original_values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    it 'clears the visible failure when an operator removes the pin' do
      Rails.application.load_tasks unless Rake::Task.task_defined?('email:unpin')
      task = Rake::Task['email:unpin']
      account = create(:account, :internal)
      pin_smtp(account)
      create(:account_config, account:, key: AccountConfig::SMTP_FAILURE_KEY,
                              value: { 'failed_at' => Time.current.iso8601, 'reason' => 'Connection failed',
                                       'notified_at' => Time.current.iso8601 })
      ENV['ACCOUNT_ID'] = account.id.to_s

      expect { task.invoke }.to output("Removed SMTP pin for account #{account.id}.\n").to_stdout
      expect(MailConfigs.resolve(account).source).to eq(:none)
      expect(AccountSmtpFailures.recent(account)).to be_nil
    ensure
      task&.reenable
    end

    # The operator mechanism end to end: the task writes the pin the resolver
    # actually honours, so a submitter email for that account leaves through
    # the pinned host with the token as credentials and the pinned From —
    # even though the platform SMTP server is configured.
    it 'pins an internal account so its submitter mail uses the pinned server over the platform one' do
      Rails.application.load_tasks unless Rake::Task.task_defined?('email:pin')
      task = Rake::Task['email:pin']
      account = create(:account, :internal, name: 'Pinned Firm')
      author = create(:user, account:)
      template = create(:template, account:, author:, attachment_count: 0)
      submission = create(:submission, template:, created_by_user: author)
      submitter = create(:submitter, submission:, uuid: template.submitters.first['uuid'])

      ENV['ACCOUNT_ID'] = account.id.to_s
      ENV['SMTP_TOKEN_ENV'] = 'GOLDEN_PIN_TOKEN'
      ENV['GOLDEN_PIN_TOKEN'] = 'golden-postmark-server-token'
      ENV['FROM_EMAIL'] = 'notices@pinned-firm.example'
      ENV['SMTP_HOST'] = 'pinned.smtp.example'

      expect { task.invoke }.to output("Pinned SMTP for account #{account.id} to pinned.smtp.example.\n").to_stdout

      ENV['EMAIL_DELIVERY_MODE'] = 'smtp'
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
      ENV['SMTP_FROM'] = 'platform@example.com'
      ENV['POSTMARK_API_TOKEN'] = 'platform-server-token'
      message = SubmitterMailer.invitation_email(submitter).message

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(Mail::SMTP)
      expect(message.delivery_method.settings).to include(
        address: 'pinned.smtp.example',
        port: '587',
        user_name: 'golden-postmark-server-token',
        password: 'golden-postmark-server-token',
        authentication: 'plain'
      )
      expect(message.from).to eq(['notices@pinned-firm.example'])
      expect(message[:from].to_s).to include('Pinned Firm')
      expect(message[:from].to_s).not_to include('platform@example.com')
    ensure
      task&.reenable
    end
  end

  it 'reports email availability only for the account pin or platform environment' do
    pinned_account = create(:account, :paid)
    unpinned_account = create(:account, :paid)
    pin_smtp(pinned_account)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

    expect(Accounts.can_send_emails?(pinned_account)).to be(true)
    expect(Accounts.can_send_emails?(unpinned_account)).to be(false)

    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'

    expect(Accounts.can_send_emails?(unpinned_account)).to be(true)
  end
end
# rubocop:enable RSpec/DescribeClass
