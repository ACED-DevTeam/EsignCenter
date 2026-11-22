# frozen_string_literal: true

RSpec.describe MarketingSocialSnapshotJob do
  it 'checks the social apps as the morning cron run by default' do
    allow(MarketingAdmin::Social).to receive(:run!)

    described_class.perform_now

    expect(MarketingAdmin::Social).to have_received(:run!).with(trigger: 'cron')
  end

  it 'passes on who asked when the page’s Refresh now button enqueued it' do
    allow(MarketingAdmin::Social).to receive(:run!)

    described_class.perform_now('manual')

    expect(MarketingAdmin::Social).to have_received(:run!).with(trigger: 'manual')
  end

  it 'stamps the run for the operator console’s scheduler tab' do
    key = "#{SchedulerStamps::KEY_PREFIX}#{described_class::STAMP}"
    Sidekiq.redis { |conn| conn.call('DEL', key) }
    allow(MarketingAdmin::Social).to receive(:run!)

    described_class.perform_now

    expect(SchedulerStamps.all.fetch('marketing_social_snapshot')).to include('outcome' => 'ok')
  ensure
    Sidekiq.redis { |conn| conn.call('DEL', key) }
  end

  it 'does nothing at all, and reaches nobody, when no app is connected' do
    stub_const('ENV', ENV.to_h.reject { |key, _| key.start_with?('MARKETING_') })

    expect { described_class.perform_now }.not_to change(MarketingSocialStatus, :count)
    expect(a_request(:any, //)).not_to have_been_made
  end
end
