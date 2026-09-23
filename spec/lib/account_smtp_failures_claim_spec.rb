# frozen_string_literal: true

RSpec.describe AccountSmtpFailures, '.claim', type: :lib do
  include_context 'with isolated SMTP environment'

  self.use_transactional_tests = false

  it 'claims exactly one notice across concurrent database connections' do
    account = create(:account, :paid)
    create(:encrypted_config, account:, key: EncryptedConfig::EMAIL_SMTP_KEY,
                              value: { host: 'customer.smtp.example', from_email: 'sender@example.com' })
    smtp_settings = Mail::SMTP.new(MailConfigs.resolve(account).smtp).settings
    error = IOError.new('connection closed')
    barrier = Queue.new
    mutex = Mutex.new
    condition = ConditionVariable.new
    arrived = 0

    # Without the account lock both workers read the empty marker before
    # either writes. With it, the first proceeds after the bounded wait and
    # the second reads the committed claim. Thread#value exposes any error.
    allow(AccountConfig).to receive(:find_or_initialize_by).and_wrap_original do |original, **args|
      original.call(**args).tap do
        mutex.synchronize do
          arrived += 1
          arrived == 2 ? condition.broadcast : condition.wait(mutex, 0.5)
        end
      end
    end
    workers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          described_class.claim(Account.find(account.id), error, smtp_settings)
        end
      end
    end
    2.times { barrier << true }

    expect(workers.filter_map(&:value).size).to eq(1)
    expect(AccountConfig.where(account:, key: AccountConfig::SMTP_FAILURE_KEY).count).to eq(1)
  ensure
    workers&.each(&:join)
    account&.destroy!
  end
end
