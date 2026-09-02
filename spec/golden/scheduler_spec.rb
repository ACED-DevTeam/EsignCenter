# frozen_string_literal: true

# The recurring-job schedule and its observed-firing evidence: the heartbeat
# job runs every minute and stamps Redis with the time it ran, which /up
# reports. Uses the real Redis the test process shares with Sidekiq.
RSpec.describe 'Scheduler', type: :lib do
  let(:schedule) { YAML.load_file(Rails.root.join('config/schedule.yml')) }
  let(:tick_key) { SchedulerHeartbeatJob::LAST_TICK_KEY }

  before do
    Sidekiq.redis { |conn| conn.call('DEL', tick_key) }
  end

  after do
    Sidekiq.redis { |conn| conn.call('DEL', tick_key) }
    Sidekiq::Cron::Job.destroy_all!
  end

  it 'declares the heartbeat every minute on the recurrent queue' do
    expect(schedule.keys).to eq(['scheduler_heartbeat'])
    expect(schedule['scheduler_heartbeat']).to include(
      'cron' => '* * * * *', 'class' => 'SchedulerHeartbeatJob', 'queue' => 'recurrent'
    )

    queues = YAML.load_file(Rails.root.join('config/sidekiq.yml')).fetch('queues').map(&:first)

    expect(queues).to include('recurrent')
    expect(queues).not_to include('rollbar')
  end

  # sidekiq-cron's own startup hook loads its default schedule file; the app
  # adds no second loader (one would re-register every job as "dynamic" and
  # defeat the purge of jobs removed from the file).
  it 'registers the heartbeat job through the gem loader the Sidekiq server runs at startup and enqueues it' do
    expect(Sidekiq::Cron.configuration.cron_schedule_file).to eq('config/schedule.yml')
    expect(Rails.root.join('config/initializers/sidekiq.rb').read).not_to include('load_from_hash!')

    Sidekiq::Cron::ScheduleLoader.new.load_schedule

    job = Sidekiq::Cron::Job.find('scheduler_heartbeat')

    expect(job).to be_present
    expect(job.source).to eq('schedule')
    expect(job.klass).to eq('SchedulerHeartbeatJob')
    expect(job.cron).to eq('* * * * *')
    expect(job.queue_name_with_prefix).to eq('recurrent')

    expect { job.enqueue! }.to change { Sidekiq::Queues['recurrent'].size }.by(1)
    expect(Sidekiq::Queues['recurrent'].last['wrapped']).to eq('SchedulerHeartbeatJob')
  end

  it 'writes the current time to the heartbeat key when performed' do
    freeze_time do
      SchedulerHeartbeatJob.new.perform

      expect(Sidekiq.redis { |conn| conn.call('GET', tick_key) }).to eq(Time.current.iso8601)
    end
  end
end
