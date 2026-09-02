# frozen_string_literal: true

# Outside the test environment a message that must not leave the box goes to
# a delivery method that drops it — never Mail::TestMailer, which keeps every
# message in memory for the life of the process. A production account with
# nowhere to send is an error-level report, and a real SMTP failure raises so
# the mail job retries instead of vanishing.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Null mail delivery', type: :lib do
  include_context 'with isolated SMTP environment'

  before do
    allow(Docuseal).to receive(:demo?).and_return(false)
  end

  def production!
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))
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

  it 'is registered with Action Mailer as :null' do
    expect(ActionMailer::Base.delivery_methods[:null]).to eq(NullMailDelivery)
  end

  it 'drops the message without retaining it or raising' do
    message = build_message
    message.delivery_method(NullMailDelivery)

    expect { message.deliver }.not_to(change { Mail::TestMailer.deliveries.size })
    expect(message.delivery_method).to be_a(NullMailDelivery)
  end

  context 'when running outside the test environment' do
    before do
      production!
      allow(ErrorReport).to receive(:error)
      allow(ErrorReport).to receive(:warning)
    end

    it 'drops mail for an account with no SMTP config and reports it as an error' do
      account = create(:account)
      allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
      message = build_message(account_id: account.id)

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(NullMailDelivery)
      expect(ErrorReport).to have_received(:error).with("no SMTP config for account #{account.id}")
      expect(ErrorReport).not_to have_received(:warning)
    end

    it 'drops a real SMTP transport when the delivery mode is not smtp' do
      message = build_message
      message.delivery_method(:smtp, address: 'platform.smtp.example', port: 587)
      allow(MailConfigs).to receive(:delivery_mode).and_return('test')

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(NullMailDelivery)
    end

    it 'drops a message already on Mail::TestMailer when the delivery mode is not smtp' do
      message = build_message
      allow(MailConfigs).to receive(:delivery_mode).and_return('test')

      expect(message.delivery_method).to be_a(Mail::TestMailer)

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(NullMailDelivery)
    end

    it 'leaves a developer transport such as letter_opener alone' do
      developer_transport = Class.new do
        attr_reader :settings

        def initialize(settings = {})
          @settings = settings
        end

        def deliver!(_mail); end
      end
      message = build_message
      message.delivery_method(developer_transport)
      allow(MailConfigs).to receive(:delivery_mode).and_return('test')

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(developer_transport)
    end

    it 'drops demo mail' do
      allow(Docuseal).to receive(:demo?).and_return(true)
      message = build_message

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(NullMailDelivery)
    end

    it 'raises SMTP delivery errors on the platform transport so the mail job retries' do
      ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
      allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
      message = build_message(account_id: create(:account).id)
      message.raise_delivery_errors = false

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(Mail::SMTP)
      expect(message.raise_delivery_errors).to be(true)
    end

    it 'raises SMTP delivery errors on a pinned account transport too' do
      account = create(:account)
      create(:encrypted_config, account:, key: EncryptedConfig::EMAIL_SMTP_KEY,
                                value: { 'host' => 'pinned.smtp.example', 'port' => '587',
                                         'from_email' => 'tenant@example.com' })
      allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
      message = build_message(account_id: account.id)
      message.raise_delivery_errors = false

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method.settings[:address]).to eq('pinned.smtp.example')
      expect(message.raise_delivery_errors).to be(true)
    end
  end

  context 'when running in the test environment' do
    it 'keeps Mail::TestMailer so specs can inspect deliveries, and only warns' do
      account = create(:account)
      allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
      allow(ErrorReport).to receive(:warning)
      allow(ErrorReport).to receive(:error)
      message = build_message(account_id: account.id)

      ActionMailerConfigsInterceptor.delivering_email(message)

      expect(message.delivery_method).to be_a(Mail::TestMailer)
      expect(ErrorReport).to have_received(:warning).with("no SMTP config for account #{account.id}")
      expect(ErrorReport).not_to have_received(:error)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
