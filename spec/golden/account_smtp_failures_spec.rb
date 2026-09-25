# frozen_string_literal: true

RSpec.describe AccountSmtpFailures, type: :lib do
  include_context 'with isolated SMTP environment'

  let(:account) { create(:account, :paid, name: 'Example Business') }
  let!(:admin) { create(:user, account:) }
  let!(:pin) do
    create(:encrypted_config, account:, key: EncryptedConfig::EMAIL_SMTP_KEY,
                              value: { host: 'customer.smtp.example', port: '587', username: 'private-user',
                                       password: 'private-password', from_email: 'sender@example.com' })
  end
  let(:failure) { Net::SMTPAuthenticationError.new('535 private-user private-password cHJpdmF0ZS1wYXNzd29yZA==') }
  let(:platform_deliveries) { [] }

  before do
    ENV['EMAIL_DELIVERY_MODE'] = 'smtp'
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    ENV['SMTP_FROM'] = 'EsignCenter <platform@example.com>'
    ENV['POSTMARK_STREAM_PAID'] = 'paid-stream'
    ENV['POSTMARK_STREAM_FREE'] = 'free-stream'
    allow(Docuseal).to receive(:demo?).and_return(false)
    # Exercise Mail's delivery and our transport rescue; stub only the wire.
    allow_any_instance_of(AccountSmtpDelivery).to receive(:start_smtp_session).and_raise(failure)
    allow_any_instance_of(Mail::SMTP).to receive(:start_smtp_session).and_return(nil)
    allow(ActionMailerEventsObserver).to receive(:delivered_email).and_wrap_original do |original, message|
      platform_deliveries << message if message.delivery_method.settings[:address] == 'platform.smtp.example'
      original.call(message)
    end
  end

  def customer_message
    Mail.new(from: 'sender@example.com', to: 'signer@example.com', subject: 'Private document title',
             body: 'Private body contents').tap do |message|
      message['X-EC-Account-Id'] = account.id.to_s
      message.instance_variable_set(:@message_metadata, { 'tag' => 'submitter_invitation' })
    end
  end

  def fail_delivery
    expect { customer_message.deliver! }.to(raise_error { |error| expect(error).to equal(failure) })
  end

  it 'sends one plain platform notice to every active admin and stores only a safe reason' do
    second_admin = create(:user, account:)
    create(:user, :editor, account:)
    create(:user, account:, archived_at: Time.current)

    fail_delivery

    expect(platform_deliveries.size).to eq(1)
    notice = platform_deliveries.first
    expect(notice.to).to contain_exactly(admin.email, second_admin.email)
    expect(notice.from).to eq(['platform@example.com'])
    expect(notice['X-PM-Message-Stream'].value).to eq('paid-stream')
    expect(notice['X-EC-Account-Id']).to be_nil
    expect(notice['X-EC-Mail-Route']).to be_nil
    body = notice.html_part.decoded
    expect(body).to include('Example Business', 'Signature request', 'signer@example.com', 'UTC',
                            'did not accept the sign-in details', '/settings/email', 'keep retrying')
    expect(body).not_to include('Private body contents', 'Private document title', 'private-password', 'private-user')
    value = described_class.recent(account)
    expect(value).to include('reason' => 'The email server did not accept the sign-in details.')
    expect(Time.iso8601(value.fetch('failed_at'))).to be_within(1.second).of(Time.current)
  end

  it 'does not record a failure or notify after a successful account delivery' do
    allow_any_instance_of(AccountSmtpDelivery).to receive(:start_smtp_session).and_return(nil)

    expect { customer_message.deliver! }.not_to raise_error
    expect(described_class.recent(account)).to be_nil
    expect(platform_deliveries).to be_empty
  end

  it 'updates the last failure without sending another notice until a full 24 hours has elapsed' do
    travel_to(Time.current.change(usec: 0)) do
      fail_delivery
      first = described_class.recent(account)
      travel 23.hours
      fail_delivery
      expect(platform_deliveries.size).to eq(1)
      expect(described_class.recent(account)['failed_at']).not_to eq(first['failed_at'])
      expect(described_class.recent(account)['notified_at']).to eq(first['notified_at'])
      travel 1.hour
      fail_delivery
      expect(platform_deliveries.size).to eq(2)
    end
  end

  it 'preserves the throttle when the visible failure is cleared' do
    fail_delivery
    described_class.clear(account)
    expect(described_class.recent(account)).to be_nil
    fail_delivery
    expect(platform_deliveries.size).to eq(1)
  end

  it 'reports notice delivery errors without replacing the original exception' do
    allow_any_instance_of(Mail::SMTP).to receive(:start_smtp_session).and_raise(IOError, 'platform secret')
    allow(ErrorReport).to receive(:error)

    fail_delivery

    expect(ErrorReport).to have_received(:error).with('Could not send SMTP failure notice',
                                                      account_id: account.id, reason: kind_of(String))
  end

  it 'reports storage errors without replacing the original exception' do
    allow(AccountConfig).to receive(:find_or_initialize_by).and_raise(ActiveRecord::StatementInvalid)
    allow(ErrorReport).to receive(:error)

    fail_delivery

    expect(ErrorReport).to have_received(:error)
    expect(platform_deliveries).to be_empty
  end

  it 'does not monitor platform-server failures' do
    allow_any_instance_of(Mail::SMTP).to receive(:start_smtp_session).and_raise(failure)

    expect { BillingMailer.suspended(account).deliver_now! }.to raise_error(Net::SMTPAuthenticationError)
    expect(described_class.recent(account)).to be_nil
    expect(platform_deliveries).to be_empty
  end

  it 'does not monitor the interactive setup test' do
    allow_any_instance_of(Mail::SMTP).to receive(:start_smtp_session).and_raise(failure)

    expect { SettingsMailer.smtp_successful_setup(admin.email, account).deliver_now! }
      .to raise_error(Net::SMTPAuthenticationError)
    expect(described_class.recent(account)).to be_nil
  end

  it 'does not notify when the pin was removed while a delivery was in flight' do
    message = customer_message
    ActionMailerConfigsInterceptor.delivering_email(message)
    pin.destroy!

    expect { message.deliver! }.to raise_error(Net::SMTPAuthenticationError)
    expect(described_class.recent(account)).to be_nil
    expect(platform_deliveries).to be_empty
  end

  it 'does not blame replacement settings for an older in-flight failure' do
    message = customer_message
    ActionMailerConfigsInterceptor.delivering_email(message)
    pin.update!(value: pin.value.merge('host' => 'replacement.smtp.example'))

    expect { message.deliver! }.to raise_error(Net::SMTPAuthenticationError)
    expect(described_class.recent(account)).to be_nil
  end

  it 'does not blame settings with removed credentials for an older authenticated send' do
    message = customer_message
    ActionMailerConfigsInterceptor.delivering_email(message)
    pin.update!(value: pin.value.except('username', 'password'))

    expect { message.deliver! }.to raise_error(Net::SMTPAuthenticationError)
    expect(described_class.recent(account)).to be_nil
  end

  it 'does not notify after an in-flight account has been downgraded' do
    message = customer_message
    ActionMailerConfigsInterceptor.delivering_email(message)
    downgrade_to_free!(account)

    expect { message.deliver! }.to raise_error(Net::SMTPAuthenticationError)
    expect(described_class.recent(account)).to be_nil
  end

  it 'notifies the pin-owning parent for inherited test-mode SMTP' do
    child = create(:account, :paid)
    account.testing_accounts << child
    message = customer_message
    message['X-EC-Account-Id'] = nil
    message['X-EC-Account-Id'] = child.id.to_s

    expect { message.deliver! }.to raise_error(Net::SMTPAuthenticationError)
    expect(platform_deliveries.first.to).to eq([admin.email])
    expect(described_class.recent(account)).to be_present
    expect(described_class.recent(child)).to be_nil
  end

  it 'covers the ActionMailer job used by deliver_later as well as synchronous delivery' do
    template = create(:template, account:, author: admin, attachment_count: 0)

    expect do
      ActionMailer::MailDeliveryJob.perform_now('TemplateMailer', 'otp_verification_email', 'deliver_now',
                                                args: [template], kwargs: { email: 'signer@example.com' })
    end.to raise_error(Net::SMTPAuthenticationError)
    expect(platform_deliveries.size).to eq(1)
    expect(platform_deliveries.first.html_part.decoded).to include('Email verification code')
  end

  it 'hides old failures on the settings page' do
    fail_delivery
    travel 25.hours

    expect(described_class.recent(account)).to be_nil
  end

  [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError,
   Net::SMTPServerBusy, Net::SMTPFatalError, RuntimeError].each do |error_class|
    it "sanitizes #{error_class} without keeping any server-supplied text" do
      reason = described_class.reason_for(error_class.new('password=private-password AUTH c2VjcmV0'))

      expect(reason).to be_present
      expect(reason).not_to include('private-password', 'AUTH', 'c2VjcmV0')
    end
  end
end
