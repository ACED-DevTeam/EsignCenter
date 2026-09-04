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
    expect(schedule.keys).to contain_exactly('scheduler_heartbeat', 'stripe_reconciliation', 'billing_lifecycle',
                                             'account_retention')
    expect(schedule['scheduler_heartbeat']).to include(
      'cron' => '* * * * *', 'class' => 'SchedulerHeartbeatJob', 'queue' => 'recurrent'
    )

    queues = YAML.load_file(Rails.root.join('config/sidekiq.yml')).fetch('queues').map(&:first)

    expect(queues).to include('recurrent')
    expect(queues).not_to include('rollbar')
  end

  # Webhooks get lost; the nightly sweep is what makes that survivable
  # (StripeReconciliationJob, docs/billing.md).
  it 'declares the Stripe reconciliation daily on its own billing queue' do
    expect(schedule['stripe_reconciliation']).to include(
      'cron' => '0 6 * * *', 'class' => 'StripeReconciliationJob', 'queue' => 'billing'
    )

    queues = YAML.load_file(Rails.root.join('config/sidekiq.yml')).fetch('queues').map(&:first)

    expect(queues).to include('billing')

    Sidekiq::Cron::ScheduleLoader.new.load_schedule

    job = Sidekiq::Cron::Job.find('stripe_reconciliation')

    expect(job).to be_present
    expect(job.source).to eq('schedule')
    expect(job.klass).to eq('StripeReconciliationJob')
    expect(job.queue_name_with_prefix).to eq('billing')
  end

  # The billing clock (D43/D57): reminder emails through the 14-day grace
  # period, the suspension at the end of it, and — since Session 7 Phase B,
  # which renamed the job from BillingDunningJob to match what it now does —
  # the seats of invitations nobody accepted. HOURLY on purpose: day 14
  # decides whether an account can still send, and a daily job would let a
  # suspended account keep sending (or keep a paid-up one suspended) for up
  # to a day (lib/billing_lifecycle.rb).
  it 'declares the billing clock hourly on the billing queue and runs every sweep' do
    expect(schedule['billing_lifecycle']).to include(
      'cron' => '15 * * * *', 'class' => 'BillingLifecycleJob', 'queue' => 'billing'
    )

    Sidekiq::Cron::ScheduleLoader.new.load_schedule

    job = Sidekiq::Cron::Job.find('billing_lifecycle')

    expect(job).to be_present
    expect(job.source).to eq('schedule')
    expect(job.klass).to eq('BillingLifecycleJob')
    expect(job.cron).to eq('15 * * * *')
    expect(job.queue_name_with_prefix).to eq('billing')

    # One tick, every sweep: a rename that quietly dropped one of them would
    # leave the dunning clock, the lapsed invitations or the seat count
    # frozen. The third (review batch 1, F2) is the backstop that brings a
    # subscription billing for more seats than are occupied back down.
    allow(BillingLifecycle).to receive(:run_dunning!)
    allow(BillingLifecycle).to receive(:expire_invites!)
    allow(BillingLifecycle).to receive(:reconcile_seats!)

    BillingLifecycleJob.new.perform

    expect(BillingLifecycle).to have_received(:run_dunning!).once
    expect(BillingLifecycle).to have_received(:expire_invites!).once
    expect(BillingLifecycle).to have_received(:reconcile_seats!).once
  end

  # The retention clock (Session 7 Phase C, D43): dormant-account warnings, the
  # week-to-go reminder before a scheduled deletion, and the purges themselves.
  # DAILY rather than hourly, because every deadline it enforces is a date; and
  # on the default queue, because a purge is ordinary work rather than
  # something the billing queue should be holding up.
  it 'declares the retention clock daily on the default queue and runs every sweep' do
    expect(schedule['account_retention']).to include(
      'cron' => '30 4 * * *', 'class' => 'AccountRetentionJob', 'queue' => 'default'
    )

    Sidekiq::Cron::ScheduleLoader.new.load_schedule

    job = Sidekiq::Cron::Job.find('account_retention')

    expect(job).to be_present
    expect(job.source).to eq('schedule')
    expect(job.klass).to eq('AccountRetentionJob')
    expect(job.cron).to eq('30 4 * * *')
    expect(job.queue_name_with_prefix).to eq('default')

    # All three sweeps, every night. A rename that quietly dropped one would
    # stop the warnings going out, or stop the purges happening at all — and
    # nothing else in the app would notice.
    allow(Accounts::Retention).to receive(:schedule_dormant_warnings!)
    allow(Accounts::Retention).to receive(:schedule_deletion_reminders!)
    allow(Accounts::Retention).to receive(:purge_due!)

    AccountRetentionJob.new.perform

    expect(Accounts::Retention).to have_received(:schedule_dormant_warnings!).once
    expect(Accounts::Retention).to have_received(:schedule_deletion_reminders!).once
    expect(Accounts::Retention).to have_received(:purge_due!).once
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
