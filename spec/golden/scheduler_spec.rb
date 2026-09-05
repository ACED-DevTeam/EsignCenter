# frozen_string_literal: true

# The recurring-job schedule and its observed-firing evidence: the heartbeat
# job runs every minute and stamps Redis with the time it ran, which /up
# reports. Uses the real Redis the test process shares with Sidekiq.
RSpec.describe 'Scheduler', type: :lib do
  let(:schedule) { YAML.load_file(Rails.root.join('config/schedule.yml')) }
  let(:tick_key) { SchedulerHeartbeatJob::LAST_TICK_KEY }
  let(:stamp_keys) { SchedulerStamps::JOB_NAMES.map { |name| "#{SchedulerStamps::KEY_PREFIX}#{name}" } }

  before do
    Sidekiq.redis { |conn| conn.call('DEL', tick_key, *stamp_keys) }
  end

  after do
    Sidekiq.redis { |conn| conn.call('DEL', tick_key, *stamp_keys) }
    Sidekiq::Cron::Job.destroy_all!
  end

  it 'declares the heartbeat every minute on the recurrent queue' do
    expect(schedule.keys).to contain_exactly('scheduler_heartbeat', 'stripe_reconciliation', 'billing_lifecycle',
                                             'account_retention', 'comp_expiry', 'housekeeping')
    expect(schedule['comp_expiry']).to include('cron' => '45 * * * *', 'class' => 'CompExpiryJob', 'queue' => 'billing')
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
    expect(SchedulerStamps.all['billing_lifecycle']).to include('outcome' => 'ok', 'error' => nil)
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

    # EVERY sweep, every night, and through the one entry point that owns the
    # list (review 8, C1/C2). A rename that quietly dropped one would stop the
    # warnings going out, stop the purges happening at all, or — as it did
    # until this session — leave every account export in the bucket past its
    # seven days and leave a build whose worker died blocking that account's
    # export door for ever. `run!` is stubbed with `and_call_original` on
    # purpose: a job that stops going through it fails on the first
    # expectation, and a sweep dropped from `run!` fails on its own.
    allow(Accounts::Retention).to receive(:run!).and_call_original
    allow(Accounts::Retention).to receive(:schedule_dormant_warnings!)
    allow(Accounts::Retention).to receive(:schedule_deletion_reminders!)
    allow(Accounts::Retention).to receive(:expire_exports!)
    allow(Accounts::Retention).to receive(:purge_due!)

    AccountRetentionJob.new.perform

    expect(Accounts::Retention).to have_received(:run!).once
    expect(Accounts::Retention).to have_received(:schedule_dormant_warnings!).once
    expect(Accounts::Retention).to have_received(:schedule_deletion_reminders!).once
    expect(Accounts::Retention).to have_received(:expire_exports!).once
    expect(Accounts::Retention).to have_received(:purge_due!).once
    expect(Accounts::Retention::SWEEPS)
      .to contain_exactly(:schedule_dormant_warnings!, :schedule_deletion_reminders!,
                          :expire_exports!, :purge_due!)
    expect(SchedulerStamps.all['account_retention']).to include('outcome' => 'ok', 'error' => nil)
  end

  # The comp clock (Session 8). It was declared in the schedule and
  # asserted a line at a time in the first example, but — unlike the other
  # four — nothing here proved that sidekiq-cron's own loader actually
  # REGISTERS it, or that a run of it lands a stamp on the operator console's
  # scheduler tab. A comp that never expires is paid access given away for
  # ever, and the stamp is the only place anybody would notice the job had
  # stopped running.
  it 'declares the comp clock hourly on the billing queue, registers it and stamps a run' do
    expect(schedule['comp_expiry']).to include(
      'cron' => '45 * * * *', 'class' => 'CompExpiryJob', 'queue' => 'billing'
    )

    Sidekiq::Cron::ScheduleLoader.new.load_schedule

    job = Sidekiq::Cron::Job.find('comp_expiry')

    expect(job).to be_present
    expect(job.source).to eq('schedule')
    expect(job.klass).to eq('CompExpiryJob')
    expect(job.cron).to eq('45 * * * *')
    expect(job.queue_name_with_prefix).to eq('billing')

    # A quiet hour is still a run: nothing is due, the sweep does nothing, and
    # the stamp says the clock ticked. That is exactly the case a broken
    # scheduler looks like from the outside, so it is the one worth pinning.
    allow(Plans::Manual).to receive(:due_comps).and_call_original

    freeze_time do
      CompExpiryJob.new.perform

      expect(Plans::Manual).to have_received(:due_comps).once
      expect(SchedulerStamps.all['comp_expiry']).to include(
        'outcome' => 'ok', 'error' => nil,
        'started_at' => Time.current.iso8601, 'finished_at' => Time.current.iso8601
      )
    end
  end

  # The hourly tidy-up (Session 10). Two states that end by themselves and
  # need something to write the ending down: a support session the operator
  # walked away from — over, but with the customer's card still saying "In
  # progress" until this runs — and a Postmark callback parked because it
  # arrived before its own send row. Asserted the same way as the comp clock:
  # declared, REGISTERED by sidekiq-cron's own loader, every sweep run, and a
  # stamp on the console's scheduler tab afterwards.
  it 'declares the hourly tidy-up, registers it and runs every sweep' do
    expect(schedule['housekeeping']).to include(
      'cron' => '5 * * * *', 'class' => 'HousekeepingJob', 'queue' => 'default'
    )

    Sidekiq::Cron::ScheduleLoader.new.load_schedule

    job = Sidekiq::Cron::Job.find('housekeeping')

    expect(job).to be_present
    expect(job.source).to eq('schedule')
    expect(job.klass).to eq('HousekeepingJob')
    expect(job.cron).to eq('5 * * * *')
    expect(job.queue_name_with_prefix).to eq('default')

    allow(SupportImpersonation).to receive(:expire_abandoned!).and_return(0)
    allow(PostmarkWebhooks).to receive(:sweep_pending!).and_return({})

    HousekeepingJob.new.perform

    expect(SupportImpersonation).to have_received(:expire_abandoned!).once
    expect(PostmarkWebhooks).to have_received(:sweep_pending!).once
    expect(HousekeepingJob::SWEEPS).to contain_exactly(:expire_support_sessions!, :sweep_pending_email_events!)
    expect(SchedulerStamps.all['housekeeping']).to include('outcome' => 'ok', 'error' => nil)
  end

  # One sweep raising must not stop the other: an operator's session left open
  # for ever is not an acceptable consequence of a webhook replay bug.
  it 'runs every sweep even when one of them raises' do
    allow(SupportImpersonation).to receive(:expire_abandoned!).and_raise(RuntimeError, 'sweep failed')
    allow(PostmarkWebhooks).to receive(:sweep_pending!).and_return({})
    allow(ErrorReport).to receive(:error)

    HousekeepingJob.new.perform

    expect(PostmarkWebhooks).to have_received(:sweep_pending!).once
    expect(ErrorReport).to have_received(:error).with(kind_of(RuntimeError))
    expect(SchedulerStamps.all['housekeeping']).to include('outcome' => 'ok')
  end

  # And the sweep list above is not the proof on its own — a stub list can
  # shrink as quietly as the job it describes. This one stubs nothing: a real
  # export whose seven days are up loses its real file when the job the
  # scheduler runs runs (review 8, C1).
  it 'really expires a ready export whose seven days are up when the retention job runs' do
    account = create(:account)
    admin = create(:user, :admin, account:)
    export = AccountExport.create!(account:, requested_by: admin, status: AccountExport::READY,
                                   started_at: 8.days.ago, finished_at: 8.days.ago, expires_at: 1.day.ago)

    export.archive.attach(io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
                          filename: 'esigncenter-export.zip', content_type: 'application/zip')

    blob = export.archive.blob

    AccountRetentionJob.new.perform

    expect(export.reload.status).to eq(AccountExport::EXPIRED)
    expect(export.archive).not_to be_attached
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
    expect(SchedulerStamps.all['account_retention']).to include('outcome' => 'ok', 'error' => nil)
  end

  # One sweep raising must not cost the others their night (review 8, C1).
  # The job still ends in a failure, so the stamp on the scheduler tab says
  # the night was bad and Sidekiq retries it — but the work that could be
  # done was done.
  it 'runs every retention sweep even when one of them raises, and stamps the failure' do
    allow(Accounts::Retention).to receive(:schedule_dormant_warnings!).and_raise(StandardError, 'mail is down')
    allow(Accounts::Retention).to receive(:schedule_deletion_reminders!)
    allow(Accounts::Retention).to receive(:expire_exports!)
    allow(Accounts::Retention).to receive(:purge_due!)

    expect { AccountRetentionJob.new.perform }.to raise_error(Accounts::Retention::SweepFailed, /mail is down/)

    expect(Accounts::Retention).to have_received(:schedule_deletion_reminders!).once
    expect(Accounts::Retention).to have_received(:expire_exports!).once
    expect(Accounts::Retention).to have_received(:purge_due!).once
    expect(SchedulerStamps.all['account_retention'])
      .to include('outcome' => 'error', 'error' => a_string_including('schedule_dormant_warnings!'))
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

  it 'stamps a completed Stripe reconciliation' do
    allow(StripeBilling).to receive(:api_key).and_return('sk_test_fake')
    job = StripeReconciliationJob.new
    allow(job).to receive(:sweep)
    allow(job).to receive(:requeue_stuck_events).and_return(0)

    freeze_time do
      job.perform
      stamp = SchedulerStamps.all.fetch('stripe_reconciliation')

      expect(stamp).to include('outcome' => 'ok', 'error' => nil,
                               'started_at' => Time.current.iso8601, 'finished_at' => Time.current.iso8601)
      expect(stamp['duration_ms']).to be >= 0
    end
  end

  it 'stamps a raised job error and re-raises it' do
    allow(BillingLifecycle).to receive(:run_dunning!).and_raise(RuntimeError, 'sweep failed')

    expect { BillingLifecycleJob.new.perform }.to raise_error(RuntimeError, 'sweep failed')
    stamp = SchedulerStamps.all.fetch('billing_lifecycle')

    expect(stamp).to include('outcome' => 'error', 'error' => 'RuntimeError: sweep failed')
    expect(stamp['started_at']).to be_present
    expect(stamp['finished_at']).to be_present
    expect(stamp['duration_ms']).to be >= 0
  end

  it 'reads the existing heartbeat into the same four-job shape' do
    expect(SchedulerStamps.all.keys).to contain_exactly(*SchedulerStamps::JOB_NAMES, 'scheduler_heartbeat')
    expect(SchedulerStamps.all.values).to all(be_nil)

    freeze_time do
      SchedulerHeartbeatJob.new.perform

      expect(SchedulerStamps.all['scheduler_heartbeat']).to eq(
        'started_at' => Time.current.iso8601, 'finished_at' => Time.current.iso8601,
        'duration_ms' => 0, 'outcome' => 'ok', 'error' => nil
      )
    end
  end
end
