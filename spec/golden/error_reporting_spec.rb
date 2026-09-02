# frozen_string_literal: true

# Sentry replaced Rollbar (D64). Every report goes through ErrorReport, which
# talks to Sentry only once a DSN has initialised it and to the Rails log
# otherwise, and which never takes the caller down.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Error reporting', type: :lib do
  let(:sentry_initializer) { Rails.root.join('config/initializers/sentry.rb') }

  it 'has no Rollbar left anywhere under app, lib or config' do
    files = Rails.root.glob('{app,lib,config}/**/*').select(&:file?)
    hits = files.select { |path| File.binread(path).match?(/rollbar/i) }

    expect(hits).to be_empty
  end

  it 'has no rollbar package left in the JavaScript dependencies' do
    expect(Rails.root.join('package.json').read).not_to match(/rollbar/i)
  end

  describe ErrorReport do
    context 'when Sentry is initialised' do
      before do
        allow(Sentry).to receive(:initialized?).and_return(true)
      end

      it 'captures exceptions at error level with the context as extras' do
        error = StandardError.new('boom')
        allow(Sentry).to receive(:capture_exception)

        described_class.error(error, submitter_id: 7)

        expect(Sentry).to have_received(:capture_exception).with(error, level: :error, extra: { submitter_id: 7 })
      end

      it 'captures messages at warning and info level' do
        allow(Sentry).to receive(:capture_message)

        described_class.warning('Already sent: 3')
        described_class.info('TTL: 4', template_id: 9)

        expect(Sentry).to have_received(:capture_message).with('Already sent: 3', level: :warning, extra: {})
        expect(Sentry).to have_received(:capture_message).with('TTL: 4', level: :info, extra: { template_id: 9 })
      end

      it 'never raises when Sentry does' do
        allow(Sentry).to receive(:capture_exception).and_raise(RuntimeError, 'sentry down')
        allow(Rails.logger).to receive(:error)

        expect { described_class.error(StandardError.new('boom')) }.not_to raise_error
        expect(Rails.logger).to have_received(:error).with('ErrorReport failed: RuntimeError: sentry down')
      end

      it 'never raises even when the emergency logger raises too' do
        allow(Sentry).to receive(:capture_exception).and_raise(RuntimeError, 'sentry down')
        allow(Rails.logger).to receive(:error).and_raise(IOError, 'closed stream')

        expect { expect(described_class.error(StandardError.new('boom'))).to be_nil }.not_to raise_error
      end
    end

    context 'when Sentry is not initialised' do
      it 'is the case in this process because no SENTRY_DSN is set' do
        expect(ENV.fetch('SENTRY_DSN', nil)).to be_nil
        expect(Sentry.initialized?).to be(false)
      end

      it 'logs at the matching level instead' do
        allow(Rails.logger).to receive_messages(error: nil, warn: nil, info: nil)

        described_class.error(StandardError.new('boom'), submitter_id: 7)
        described_class.warning('Already sent: 3')
        described_class.info('TTL: 4')

        expect(Rails.logger).to have_received(:error).with('StandardError: boom {"submitter_id":7}')
        expect(Rails.logger).to have_received(:warn).with('Already sent: 3')
        expect(Rails.logger).to have_received(:info).with('TTL: 4')
      end
    end
  end

  # Redis unreachable: the rate-limit store fails open (every limit is off)
  # and says so through the one seam, so the outage is visible in Sentry.
  describe RateLimit do
    let(:unreachable_redis) do
      Class.new do
        def method_missing(*)
          raise Redis::CannotConnectError, 'redis down'
        end

        def respond_to_missing?(*)
          false
        end
      end.new
    end

    let(:store) do
      ActiveSupport::Cache::RedisCacheStore.new(redis: unreachable_redis, pool: false, namespace: 'rate_limit',
                                                error_handler: described_class.method(:report_store_error))
    end

    before do
      allow(Sentry).to receive(:initialized?).and_return(true)
      allow(Sentry).to receive(:capture_exception)
      allow(described_class).to receive(:store).and_return(store)
    end

    it 'fails open and reports the store error to Sentry at warning level' do
      expect(described_class.call('golden', limit: 1, ttl: 1.minute)).to be(true)
      expect(described_class.call('golden', limit: 1, ttl: 1.minute)).to be(true)

      expect(Sentry).to have_received(:capture_exception)
        .with(an_instance_of(Redis::CannotConnectError), level: :warning, extra: { method: :increment, returning: nil })
        .twice
    end
  end

  describe 'config/initializers/sentry.rb' do
    let(:sentry_env_keys) { %w[SENTRY_DSN SENTRY_ENVIRONMENT] }

    around do |example|
      original_values = sentry_env_keys.index_with { |key| ENV.fetch(key, nil) }
      sentry_env_keys.each { |key| ENV.delete(key) }

      example.run
    ensure
      Sentry.close if Sentry.initialized?
      original_values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    it 'stays dormant without SENTRY_DSN' do
      load sentry_initializer

      expect(Sentry.initialized?).to be(false)
    end

    it 'initialises with PII off, errors only, and routes ErrorReport to Sentry' do
      ENV['SENTRY_DSN'] = 'https://public@example.ingest.sentry.io/1'
      ENV['SENTRY_ENVIRONMENT'] = 'golden'

      load sentry_initializer

      expect(Sentry.initialized?).to be(true)

      config = Sentry.configuration

      expect(config.send_default_pii).to be(false)
      expect(config.traces_sample_rate).to eq(0.0)
      expect(config.environment).to eq('golden')
      expect(config.breadcrumbs_logger).to eq([:active_support_logger])

      allow(Sentry).to receive(:capture_message)

      ErrorReport.warning('golden')

      expect(Sentry).to have_received(:capture_message).with('golden', level: :warning, extra: {})
    end

    it 'defaults the environment to the Rails environment' do
      ENV['SENTRY_DSN'] = 'https://public@example.ingest.sentry.io/1'

      load sentry_initializer

      expect(Sentry.configuration.environment).to eq('test')
    end

    # Rails' own error reporter (Rails.error) is a second reporting path used
    # by framework internals; it forwards to Sentry only when the subscriber
    # is registered, which the railtie does at boot from this setting.
    it 'registers the Rails.error subscriber so those reports reach Sentry too' do
      ENV['SENTRY_DSN'] = 'https://public@example.ingest.sentry.io/1'

      load sentry_initializer

      expect(Sentry.configuration.rails.register_error_subscriber).to be(true)

      # The railtie subscribes in after_initialize, which already ran in this
      # process without a DSN — do exactly what it does then.
      Sentry::Railtie.instance.register_error_subscriber(Rails.application)
      allow(Sentry).to receive(:capture_exception)
      error = RuntimeError.new('x')

      Rails.error.report(error, handled: true)

      expect(Sentry).to have_received(:capture_exception)
        .with(error, hash_including(level: :warning, tags: hash_including(handled: true)))
    ensure
      Rails.error.unsubscribe(Sentry::Rails::ErrorSubscriber) if defined?(Sentry::Rails::ErrorSubscriber)
    end
  end

  describe StorageConfigGuard do
    let(:storage_env_keys) { StorageConfigGuard::STORAGE_ENV_KEYS }

    around do |example|
      original_values = storage_env_keys.index_with { |key| ENV.fetch(key, nil) }
      storage_env_keys.each { |key| ENV.delete(key) }

      example.run
    ensure
      original_values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    def production!
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))
    end

    def create_storage_row
      create(:encrypted_config, account: create(:account), key: EncryptedConfig::FILES_STORAGE_KEY,
                                value: { 'service' => 'disk' })
    end

    before do
      allow(ErrorReport).to receive(:warning)
      allow(Rails.logger).to receive(:warn)
    end

    it 'warns in production when a storage row exists but no storage env var is set' do
      create_storage_row
      production!

      described_class.check!

      expect(ErrorReport).to have_received(:warning).with(/active_storage config rows exist/)
      expect(Rails.logger).to have_received(:warn).with(/active_storage config rows exist/)
    end

    it 'is silent when a storage bucket is configured' do
      create_storage_row
      production!
      ENV['S3_ATTACHMENTS_BUCKET'] = 'attachments'

      described_class.check!

      expect(ErrorReport).not_to have_received(:warning)
    end

    it 'is silent when no storage row exists' do
      production!

      described_class.check!

      expect(ErrorReport).not_to have_received(:warning)
    end

    it 'is silent outside production' do
      create_storage_row

      described_class.check!

      expect(ErrorReport).not_to have_received(:warning)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
