# frozen_string_literal: true

# Platform mail leaves on a Postmark message stream chosen by plan: a free
# account's mail on the free stream, everything else (paid, internal, mail
# with no account such as operator alerts) on the paid stream. A pinned
# per-account server never gets the header, and with either env var
# missing no header is set at all.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Postmark stream by plan', type: :lib do
  include_context 'with isolated SMTP environment'

  let(:stream_keys) { %w[POSTMARK_STREAM_PAID POSTMARK_STREAM_FREE] }

  around do |example|
    original = stream_keys.index_with { |key| ENV.fetch(key, nil) }
    stream_keys.each { |key| ENV.delete(key) }

    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before do
    allow(Docuseal).to receive(:demo?).and_return(false)
    allow(MailConfigs).to receive(:delivery_mode).and_return('smtp')
    ENV['SMTP_ADDRESS'] = 'platform.smtp.example'
    ENV['SMTP_FROM'] = 'platform@example.com'
  end

  def streams!
    ENV['POSTMARK_STREAM_PAID'] = 'outbound-paid'
    ENV['POSTMARK_STREAM_FREE'] = 'outbound-free'
  end

  def build_message(account_id: nil)
    Mail.new(from: 'Sender <sender@example.com>', to: 'recipient@example.com', subject: 'Hello', body: 'Hi').tap do |m|
      m.delivery_method(:test)
      m['X-EC-Account-Id'] = account_id.to_s if account_id
    end
  end

  def stream_of(message)
    ActionMailerConfigsInterceptor.delivering_email(message)

    message['X-PM-Message-Stream']&.value
  end

  def pin_smtp(account)
    create(:encrypted_config, account:, key: EncryptedConfig::EMAIL_SMTP_KEY,
                              value: { 'host' => 'pinned.smtp.example', 'port' => '587', 'username' => 'u',
                                       'password' => 'p', 'from_email' => 'tenant@example.com',
                                       'authentication' => 'plain' })
  end

  it 'puts a free account on the free stream and a paid one on the paid stream' do
    streams!

    expect(stream_of(build_message(account_id: create(:account).id))).to eq('outbound-free')
    expect(stream_of(build_message(account_id: create(:account, :paid).id))).to eq('outbound-paid')
  end

  it 'moves an account between streams with its plan, and bills a testing child through its parent' do
    streams!
    account = create(:account, :paid, :with_testing_account)

    expect(stream_of(build_message(account_id: account.testing_accounts.first.id))).to eq('outbound-paid')

    downgrade_to_free!(account)

    expect(stream_of(build_message(account_id: account.id))).to eq('outbound-free')
    expect(stream_of(build_message(account_id: account.testing_accounts.first.id))).to eq('outbound-free')
  end

  it 'puts internal, operator and account-less mail (operator alerts) on the paid stream' do
    streams!

    expect(stream_of(build_message(account_id: create(:account, :internal).id))).to eq('outbound-paid')
    expect(stream_of(build_message(account_id: create(:account, :operator).id))).to eq('outbound-paid')
    expect(stream_of(build_message)).to eq('outbound-paid')

    alert = OperatorMailer.alert('Something', 'Body').message

    expect(alert['X-EC-Account-Id']).to be_nil
    expect(alert.to).to eq([Docuseal::SUPPORT_EMAIL])
    expect(stream_of(alert)).to eq('outbound-paid')
  end

  it 'sends real quota mail for a free account on the free stream' do
    streams!
    account = create(:account)
    create(:user, account:)

    message = QuotaMailer.completions_warning(account).message

    expect(message['X-EC-Account-Id']&.value).to eq(account.id.to_s)
    expect(stream_of(message)).to eq('outbound-free')
  end

  it 'never sets the header on a pinned account server' do
    streams!
    # Per-account SMTP is a paid row, so a pinned account is a paid one.
    account = create(:account, :paid)
    pin_smtp(account)
    message = build_message(account_id: account.id)

    expect(stream_of(message)).to be_nil
    expect(message.delivery_method.settings[:address]).to eq('pinned.smtp.example')

    # And the same account's plan decides the stream only when the mail
    # leaves through the platform server.
    downgrade_to_free!(account)
    EncryptedConfig.where(account:).delete_all

    expect(stream_of(build_message(account_id: account.id))).to eq('outbound-free')
  end

  it 'sets no header when either stream variable is missing' do
    free = create(:account)

    expect(stream_of(build_message(account_id: free.id))).to be_nil

    ENV['POSTMARK_STREAM_PAID'] = 'outbound-paid'
    expect(stream_of(build_message(account_id: free.id))).to be_nil

    ENV.delete('POSTMARK_STREAM_PAID')
    ENV['POSTMARK_STREAM_FREE'] = 'outbound-free'
    expect(stream_of(build_message(account_id: free.id))).to be_nil
  end
end
# rubocop:enable RSpec/DescribeClass
