# frozen_string_literal: true

# Checkpoint 7, reviewer C: the parts of the account lifecycle whose proofs
# were missing, and the safety rails the review asked for.
#
# The rules pinned here, in one sentence each:
#
#   * the operator's "purge now" command destroys an account only when the
#     account is actually due to be destroyed, and never one that another
#     purge has already claimed;
#   * a purge that has claimed an account is nobody else's to run — the
#     nightly sweep stops enqueueing it and a second job stands down;
#   * cancelling a deletion never hands paid features back over a subscription
#     Stripe has already cancelled;
#   * a warning letter belongs to ONE dormancy;
#   * nothing that could lead a reader back to the customer survives in the
#     Stripe events we keep, and a late event about a tombstone is scrubbed on
#     the way in;
#   * `completed_documents` is counted against ids written down before the
#     walk, like every other table whose parent the walk deletes.
#
# Everything is driven through the real doors: the rake tasks through Rake
# itself, the cancel through the controller route, the sweep through
# `Accounts::Retention`.
RSpec.describe 'The operator purge command', type: :request do # rubocop:disable RSpec/MultipleDescribes
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:, password: 'correct horse battery') }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }

  before do
    platform_certificate!
    template
    Rails.application.load_tasks unless Rake::Task.task_defined?('accounts:purge')
  end

  # The task reads its two safety switches out of the environment, so they are
  # put back whatever the example does.
  around do |example|
    force = ENV.fetch('FORCE', nil)
    confirm = ENV.fetch('CONFIRM', nil)

    example.run
  ensure
    ENV['FORCE'] = force
    ENV['CONFIRM'] = confirm
  end

  # A refusal ends in `abort`, which prints to stderr and raises SystemExit,
  # so both halves are captured: did the task go through, and what did the
  # operator actually see.
  def run_task(name, id)
    out = StringIO.new
    err = StringIO.new
    original = [$stdout, $stderr]
    $stdout = out
    $stderr = err
    completed = true

    begin
      task = Rake::Task["accounts:#{name}"]
      task.reenable
      task.invoke(id)
    rescue SystemExit
      completed = false
    end

    [completed, out.string + err.string]
  ensure
    $stdout, $stderr = original
  end

  def rows_intact!
    account.reload

    expect(account.purged_at).to be_nil
    expect(account.archived_at).to be_nil
    expect(Template.where(account_id: account.id).count).to eq(1)
    expect(User.where(account_id: account.id).count).to eq(1)
  end

  def due_for_deletion!
    account.update!(deletion_requested_at: 91.days.ago, purge_scheduled_for: 1.minute.ago)
  end

  # C2. The command used to destroy ANY customer account on one mistyped id:
  # it printed "deletion requested: (never)" and then emptied it anyway.
  it 'refuses an account nobody asked to delete, and leaves every row where it was' do
    completed, output = run_task('purge', account.id)

    expect(completed).to be(false)
    expect(output).to include('is not due to be purged')
    expect(account.reload.purge_started_at).to be_nil
    rows_intact!
  end

  it 'refuses a dormant account that has not had its final warning yet' do
    account.update!(created_at: 3.years.ago)
    User.where(account_id: account.id).update_all(current_sign_in_at: 13.months.ago)

    completed, = run_task('purge', account.id)

    expect(completed).to be(false)
    rows_intact!
  end

  # C7. Two walks over one family is the thing to avoid, and the operator
  # answering an alert while the job's retry is still alive is how it happens.
  it 'refuses an account another purge has already claimed' do
    due_for_deletion!
    Accounts::Purge.claim!(account)

    completed, output = run_task('purge', account.id)

    expect(completed).to be(false)
    expect(output).to include('already claimed')
    expect(output).to include('release_purge_claim')

    account.reload

    # The claim is left exactly as it was: this command does not get to
    # release somebody else's.
    expect(account.purge_started_at).to be_present
    expect(account.purged_at).to be_nil
    expect(Template.where(account_id: account.id).count).to eq(1)
  end

  # FORCE is the door for the account that really does have to go now — an
  # abuse case, a support request — and it makes the operator read what they
  # are about to destroy and type the name back.
  it 'shows what FORCE would destroy and still refuses until the name is typed back' do
    ENV['FORCE'] = '1'

    completed, output = run_task('purge', account.id)

    expect(completed).to be(false)
    expect(output).to include(account.name)
    expect(output).to include('templates: 1')
    expect(output).to include('users: 1')
    expect(output).to include('CONFIRM=')
    rows_intact!
  end

  it 'refuses FORCE when the name typed back is not the account name' do
    ENV['FORCE'] = '1'
    ENV['CONFIRM'] = 'Some other company'

    completed, output = run_task('purge', account.id)

    expect(completed).to be(false)
    expect(output).to include('does not match')
    rows_intact!
  end

  it 'destroys the account when FORCE is asked for and the name matches', sidekiq: :inline do
    ENV['FORCE'] = '1'
    ENV['CONFIRM'] = account.name

    completed, output = run_task('purge', account.id)

    expect(completed).to be(true)
    expect(output).to include('Purged.')
    expect(account.reload.purged_at).to be_present
    expect(Template.where(account_id: account.id).count).to eq(0)
    expect(User.where(account_id: account.id).count).to eq(0)
  end

  # The refusals inside the purge itself still stand above FORCE, and the
  # claim this command took is released again when they fire.
  it 'releases the claim it took when the purge refuses even under FORCE' do
    create(:account_subscription, account:, access_state: 'active')
    ENV['FORCE'] = '1'
    ENV['CONFIRM'] = account.name

    completed, output = run_task('purge', account.id)

    expect(completed).to be(false)
    expect(output).to include('live paid subscription')

    account.reload

    expect(account.purge_started_at).to be_nil
    rows_intact!
  end
end

# C7 proper: the claim is a claim. Once one purge holds it, the sweep stops
# offering the account to anybody else and a job that did not make the claim
# stands down rather than walking the family a second time.
RSpec.describe 'An account a purge has already claimed', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:) }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }

  before do
    platform_certificate!
    template
  end

  def due_for_deletion!
    account.update!(deletion_requested_at: 91.days.ago, purge_scheduled_for: 1.minute.ago)
  end

  # What the sweep actually handed to the queue, read off Sidekiq's own fake
  # queue (this app's ActiveJob adapter is Sidekiq).
  def purge_jobs_on_the_queue
    Sidekiq::Queues.jobs_by_queue.values.flatten.select { |job| job.to_json.include?('AccountPurgeJob') }
  end

  # The dormant clock, wound through the real sweep rather than by stamping
  # the columns (the same shape lifecycle_downgrade_spec uses): nothing
  # dormant is purgeable until the final warning has actually been delivered.
  def dormant_and_warned!
    account.update!(created_at: 3.years.ago)
    User.where(account_id: account.id).update_all(current_sign_in_at: 13.months.ago)
    account.reload

    moment = Accounts::Retention.dormant_purge_at(account) -
             Accounts::Retention::FINAL_WARNING_DAYS.days + 1.hour

    travel_to(moment) { Accounts::Retention.schedule_dormant_warnings! }

    account.reload
  end

  it 'is no longer offered by the nightly sweep once it is claimed' do
    due_for_deletion!

    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

    Accounts::Purge.claim!(account)

    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)

    Sidekiq::Worker.clear_all
    Accounts::Retention.purge_due!

    expect(purge_jobs_on_the_queue).to be_empty
  end

  it 'is no longer offered by the nightly sweep when it is dormant rather than asked for' do
    dormant_and_warned!

    expect(Accounts::Retention.purge_candidates.map(&:id)).to include(account.id)

    Accounts::Purge.claim!(account)

    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)

    Sidekiq::Worker.clear_all
    Accounts::Retention.purge_due!

    expect(purge_jobs_on_the_queue).to be_empty
  end

  # A job that finds the account already claimed on its FIRST attempt did not
  # make that claim: somebody else is walking the family right now, and two
  # walks over one family is what this stops.
  it 'is left alone by a second job that did not claim it', sidekiq: :inline do
    due_for_deletion!
    Accounts::Purge.claim!(account)

    AccountPurgeJob.perform_now(account.id)

    expect(account.reload.purged_at).to be_nil
    expect(Template.where(account_id: account.id).count).to eq(1)
    expect(User.where(account_id: account.id).count).to eq(1)
  end

  # And the retry of the job that DID claim it still finishes the work — a
  # half-emptied account no longer looks eligible, so a resume must not
  # re-decide.
  it 'is still finished by a retry of the job that claimed it', sidekiq: :inline do
    due_for_deletion!
    Accounts::Purge.claim!(account)

    job = AccountPurgeJob.new(account.id)
    job.executions = 1

    job.perform_now

    expect(account.reload.purged_at).to be_present
    expect(Template.where(account_id: account.id).count).to eq(0)
  end
end

# C3: the proof the "cancelled at Stripe but the row still says paid" fix
# never had. Two halves — the ordinary case, where Stripe's answer is written
# down at once and there is nothing left to settle; and the case the guard
# exists for, where Stripe was unreachable and the account must stay frozen
# rather than come back on paid features nobody is being charged for.
RSpec.describe 'Cancelling a deletion whose billing has not settled', type: :request do
  include_context 'with a Stripe test account'

  let(:account) { create(:account) }
  let(:admin) { create(:user, account:, password: 'correct horse battery') }
  let(:deliveries) { ActionMailer::Base.deliveries }
  let!(:row) do
    create(:account_subscription, account:, access_state: 'active', status: 'active',
                                  stripe_subscription_id: subscription_a, stripe_customer_id: customer_a)
  end

  before do
    platform_certificate!
    deliveries.clear
    RateLimit.store.clear
    Rails.application.load_tasks unless Rake::Task.task_defined?('accounts:cancel_deletion')
  end

  def subscription_url
    %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{Regexp.escape(subscription_a)}}
  end

  # The metadata marker always lands; only the cancel itself is made to fail,
  # which is exactly the shape of "Stripe was unreachable at that moment".
  def stub_mark
    stub_request(:post, subscription_url)
      .to_return(status: 200, body: { id: subscription_a, object: 'subscription' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  def stub_working_cancel
    stub_mark
    stub_request(:delete, subscription_url)
      .to_return(status: 200, body: fixture_body('subscription-canceled'),
                 headers: { 'Content-Type' => 'application/json' })
  end

  def stub_broken_cancel
    stub_mark
    stub_request(:delete, subscription_url)
      .to_return(status: 500, body: { error: { message: 'Stripe is having a moment' } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  def run_task(name, id)
    out = StringIO.new
    err = StringIO.new
    original = [$stdout, $stderr]
    $stdout = out
    $stderr = err
    completed = true

    begin
      task = Rake::Task["accounts:#{name}"]
      task.reenable
      task.invoke(id)
    rescue SystemExit
      completed = false
    end

    [completed, out.string + err.string]
  ensure
    $stdout, $stderr = original
  end

  # The whole point of applying Stripe's answer under the row lock: the
  # account is on the free plan the moment the deletion is asked for, not
  # whenever a webhook happens to arrive.
  it 'writes Stripe cancellation into the row before any webhook arrives' do
    stub_working_cancel

    Accounts::Deletion.request!(account, requested_by: admin)

    row.reload
    account.reload

    expect(row.access_state).to eq('cancelled')
    expect(Plans.key_for(account)).to eq(Plans::FREE)
    expect(Plans.paid_subscription?(account)).to be(false)
    expect(StripeEventInbox.count).to eq(0)
  end

  it 'refuses to unfreeze the account while the row still reads paid' do
    stub_broken_cancel

    Accounts::Deletion.request!(account, requested_by: admin)

    # Stripe never answered, so the row is exactly as it was and the retrying
    # job is carrying the cancellation.
    expect(row.reload.access_state).to eq('active')

    expect { Accounts::Deletion.cancel!(account.reload) }
      .to raise_error(Accounts::Deletion::BillingUnsettled)

    account.reload

    expect(account.deletion_requested_at).to be_present
    expect(account.suspended_at).to be_present
    expect(account.suspension_reason).to eq('deletion')
  end

  # NOT inline: the retrying job is the thing being asserted, so it has to be
  # left on the queue rather than run (and re-run, and re-run) here.
  def cancel_jobs_on_the_queue
    Sidekiq::Queues.jobs_by_queue.values.flatten
                   .select { |job| job.to_json.include?('CancelDeletedSubscriptionJob') }
  end

  it 'says so on the settings page and changes nothing' do
    stub_broken_cancel

    Accounts::Deletion.request!(account, requested_by: admin)
    account.reload
    Sidekiq::Worker.clear_all

    sign_in(admin)
    post '/settings/account/cancel_deletion'

    # The cancellation is still being carried by the retrying job rather than
    # being forgotten about.
    expect(cancel_jobs_on_the_queue.size).to eq(1)
    expect(cancel_jobs_on_the_queue.first.to_json).to include(account.id.to_s)

    expect(flash[:alert]).to eq(I18n.t('account_deletion_billing_not_settled'))
    expect(flash[:notice]).to be_blank

    account.reload

    expect(account.deletion_requested_at).to be_present
    expect(account.purge_scheduled_for).to be_present
    expect(account.suspended_at).to be_present
    expect(account.suspension_reason).to eq('deletion')
    expect(deliveries.map(&:subject)).not_to include('Your EsignCenter account will not be deleted')
  end

  # And the operator's door says the same thing rather than reporting a
  # cancellation that did not happen.
  it 'leaves the account alone when the operator runs the rake task' do
    stub_broken_cancel

    Accounts::Deletion.request!(account, requested_by: admin)

    completed, output = run_task('cancel_deletion', account.id)

    expect(completed).to be(false)
    expect(output).to include('was left alone')
    expect(output).to include('CancelDeletedSubscriptionJob')

    account.reload

    expect(account.deletion_requested_at).to be_present
    expect(account.suspended_at).to be_present
  end

  # The ordinary cancel, for contrast: Stripe answered when the deletion was
  # asked for, so there is nothing to settle and the account comes back.
  it 'cancels normally when the subscription really was cancelled', sidekiq: :inline do
    stub_working_cancel

    Accounts::Deletion.request!(account, requested_by: admin)

    sign_in(admin)
    post '/settings/account/cancel_deletion'

    account.reload

    expect(flash[:notice]).to eq(I18n.t('account_deletion_cancelled_notice'))
    expect(account.deletion_requested_at).to be_nil
    expect(account.suspended_at).to be_nil
    expect(Plans.key_for(account)).to eq(Plans::FREE)
  end
end

# C4: the guard the review's mutation survived. An account can go quiet, be
# warned, come back, and go quiet again a year later — and the letter from the
# first cycle must not authorize the second deletion.
RSpec.describe 'A dormant warning that belongs to an earlier dormancy', type: :request do
  let(:account) { create(:account, created_at: 3.years.ago) }
  let(:owner) { create(:user, account:, created_at: 3.years.ago, current_sign_in_at: 13.months.ago) }

  before { owner }

  # No sweep runs in this example, and that is the point: the sweep clears a
  # stale stamp on its way past, so with one in between it is the CLEARING
  # rather than the guard that decides. Asked directly, the guard is what
  # stands between an account that was warned about a dormancy that ended and
  # a deletion nobody heard about.
  it 'does not authorize this dormancy even when no sweep has cleared it' do
    account.update_columns(dormant_warning_sent_at: 14.months.ago, dormant_warning_for: 13.months.ago)

    expect(Accounts::Retention.dormant?(account)).to be(true)
    expect(account.dormant_warning_sent_at).to be < Accounts::Retention.last_activity_at(account)

    expect(Accounts::Retention.dormant_purgeable?(account)).to be(false)
    expect(Accounts::Retention.purge_eligible?(account)).to be(false)
    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)
  end

  # And the stale stamp is cleared even for an account the sweep is not going
  # to warn, because it is inside its paid-retention year. It used to survive
  # until that year ran out, which is a year of a row carrying evidence about
  # a dormancy that ended.
  it 'is cleared by the sweep even while the account is inside its paid year' do
    create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                  stripe_subscription_id: 'sub_long_gone', ended_at: 6.months.ago)
    account.update_columns(dormant_warning_sent_at: 14.months.ago, dormant_warning_for: 13.months.ago)

    Accounts::Retention.schedule_dormant_warnings!

    account.reload

    expect(account.dormant_warning_sent_at).to be_nil
    expect(account.dormant_warning_for).to be_nil

    # The paid year is what protects it, and it still does.
    expect(Accounts::Retention.within_paid_retention?(account)).to be(true)
    expect(Accounts::Retention.purge_candidates.map(&:id)).not_to include(account.id)
  end
end

# C5: what is left of the customer in the Stripe events we keep. Every event
# Stripe sends about an invoice carries an unguessable link to a Stripe-hosted
# page that renders the customer's name, address and email — so the link is as
# personal as the address itself.
RSpec.describe 'What a purge leaves in the Stripe audit', type: :request do
  include_context 'with a Stripe test account'

  let(:account) { create(:account) }
  let(:admin) { create(:user, account:) }

  before do
    platform_certificate!
    admin
  end

  # The subscription row a purge deliberately KEEPS: cancelled, but still
  # naming the Stripe customer and subscription, which is how a late event
  # finds its way back to the tombstone.
  def kept_row
    create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                  stripe_customer_id: customer_a, stripe_subscription_id: subscription_a)
  end

  def stub_kept_subscription
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{Regexp.escape(subscription_a)}})
      .with(query: hash_including('expand' => StripeBilling::SUBSCRIPTION_EXPAND))
      .to_return(status: 200, body: fixture_body('subscription-canceled'),
                 headers: { 'Content-Type' => 'application/json' })
  end

  # THE REAL FRONT DOOR (checkpoint 7, P2). Signed the way Stripe signs a
  # delivery and posted as raw bytes — and, like every real delivery, naming
  # no account: which account an event belongs to is worked out later by
  # ProcessStripeEventJob, and that is the moment a tombstone has to be
  # noticed. A test that inserts the row with the account already on it
  # proves nothing about this path.
  def post_signed_event(body)
    at = Time.now.utc
    signature = Stripe::Webhook::Signature.compute_signature(at, body, webhook_secret)

    post stripe_webhooks_path, params: body,
                               headers: { 'Stripe-Signature' => "t=#{at.to_i},v1=#{signature}",
                                          'CONTENT_TYPE' => 'application/json' }
  end

  # Every capture in the repository, not a chosen one: a key that is scrubbed
  # in the fixture somebody thought of and not in the next one is exactly the
  # residue this is about.
  def every_fixture
    Rails.root.glob('spec/fixtures/stripe/**/*.json').sort
  end

  def store!(payload)
    StripeEventInbox.create!(account_id: account.id, stripe_event_id: "evt_#{SecureRandom.hex(8)}",
                             event_type: JSON.parse(payload)['type'] || 'stripe.object',
                             payload:, status: 'processed', stripe_created_at: Time.current)
  end

  it 'keeps no link back to a Stripe-hosted page, in any capture we hold' do
    stored = every_fixture.map { |path| store!(path.read) }

    # The fixtures really do carry them, or this proves nothing.
    expect(stored.count { |inbox| inbox.payload.include?('stripe.com/i/') }).to be_positive
    expect(stored.count { |inbox| inbox.payload.include?('pay.stripe.com') }).to be_positive

    Accounts::Purge.call(account)

    stored.each do |inbox|
      inbox.reload

      expect(inbox.payload).not_to include('stripe.com/i/')
      expect(inbox.payload).not_to include('pay.stripe.com')
      expect(inbox.payload).not_to include('invoice.stripe.com')
    end

    # And the audit is still an audit: the ids and the money are untouched.
    paid = stored.find { |inbox| inbox.event_type == 'invoice.paid' }.reload

    expect(paid.event_object['hosted_invoice_url']).to eq(Accounts::Purge::REDACTED)
    expect(paid.event_object['invoice_pdf']).to eq(Accounts::Purge::REDACTED)
    expect(paid.event_object['id']).to be_present
    expect(paid.event_object['amount_paid']).to be_a(Integer)
  end

  # The other half: Stripe keeps talking about a subscription for a while
  # after the account is a tombstone, and those late events used to be stored
  # exactly as they arrived — raw, with the customer inside them.
  #
  # Driven through the webhook endpoint with a body that ends at the closing
  # brace, which is what a real Stripe delivery looks like. The version of
  # this fix that went through a fixture body (trailing newline) and a row
  # inserted with the account already on it passed while production stored
  # the customer's email, name, address and a working invoice link (P2).
  it 'scrubs a late event that arrives through the webhook door after the account is a tombstone' do
    kept_row
    Accounts::Purge.call(account)

    expect(account.reload.purged_at).to be_present

    stub_kept_subscription

    body = fixture_body('event-invoice.paid').strip

    # The delivery really does carry all of it, or this proves nothing.
    expect(body).to include('invoice.stripe.com')
    expect(body).to include('fixture@example.com')

    post_signed_event(body)

    expect(response).to have_http_status(:ok)

    ProcessStripeEventJob.drain

    inbox = StripeEventInbox.sole

    # The row really did reach the tombstone — this is the attribution that
    # the scrub now hangs off.
    expect(inbox.account_id).to eq(account.id)
    expect(inbox.status).to eq('processed')

    expect(inbox.payload).not_to include('stripe.com/i/')
    expect(inbox.payload).not_to include('pay.stripe.com')
    expect(inbox.payload).not_to include('invoice.stripe.com')
    expect(inbox.payload).not_to include('fixture@example.com')
    expect(inbox.payload).not_to include('EsignCenter Fixture Co')
    expect(inbox.event_object['hosted_invoice_url']).to eq(Accounts::Purge::REDACTED)
    expect(inbox.event_object['invoice_pdf']).to eq(Accounts::Purge::REDACTED)
    expect(inbox.event_object['customer_email']).to eq(Accounts::Purge::REDACTED)
    expect(inbox.event_object['customer_name']).to eq(Accounts::Purge::REDACTED)

    # Still readable as an event, which is what the row is kept for.
    expect(inbox.event['type']).to eq('invoice.paid')
    expect(inbox.event_object['id']).to be_present
    expect(inbox.event_object['amount_paid']).to be_a(Integer)
  end

  it 'scrubs a late event that arrives after the account is a tombstone' do
    Accounts::Purge.call(account)

    expect(account.reload.purged_at).to be_present

    inbox = store!(Rails.root.join('spec/fixtures/stripe/event-invoice.paid.json').read)

    inbox.reload

    expect(inbox.payload).not_to include('stripe.com/i/')
    expect(inbox.payload).not_to include('pay.stripe.com')
    expect(inbox.event_object['hosted_invoice_url']).to eq(Accounts::Purge::REDACTED)
    expect(inbox.event_object['customer_email']).to eq(Accounts::Purge::REDACTED)

    # Still readable as an event, which is what the row is kept for.
    expect(inbox.event['type']).to eq('invoice.paid')
    expect(inbox.event_object['id']).to be_present
  end

  it 'leaves an ordinary account\'s events exactly as Stripe signed them' do
    payload = Rails.root.join('spec/fixtures/stripe/event-invoice.paid.json').read
    inbox = store!(payload)

    expect(inbox.reload.payload).to eq(payload)
  end

  # And the same door for an account that is alive: nothing is scrubbed, and
  # the bytes are still the ones Stripe signed AFTER the job has stamped the
  # account onto the row — trailing newline and all, which is the whole
  # promise the model's header makes about this column.
  it 'stores a live account\'s event through the same door exactly as Stripe signed it' do
    kept_row
    stub_kept_subscription

    body = fixture_body('event-invoice.paid')

    post_signed_event(body)

    expect(response).to have_http_status(:ok)

    ProcessStripeEventJob.drain

    inbox = StripeEventInbox.sole

    expect(inbox.account_id).to eq(account.id)
    expect(inbox.payload).to eq(body)
    expect(inbox.payload).to include('invoice.stripe.com')
    expect(inbox.event_object['customer_email']).to eq('fixture@example.com')
  end
end

# C4/P-L2-1 (carried from review 7): `completed_documents` is the one
# inventory table with no foreign key that used to be counted through a parent
# the walk had already deleted — so the count could only ever read zero, and a
# row written mid-purge was entombed under a tombstone claiming the account
# was empty.
RSpec.describe 'A document fingerprint written in the middle of a purge', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:, password: 'correct horse battery') }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }

  before { platform_certificate! }

  def submitter!
    Submissions.create_from_emails(template:, user: admin, emails: 'signer@example.com',
                                   source: :invite, mark_as_sent: true).sole.submitters.first
  end

  # What a document generation finishing mid-purge writes: a fingerprint
  # against a submitter whose row the walk has already taken. There is no
  # foreign key behind that column, so the database says nothing.
  def insert_straggler!(submitter_id)
    CompletedDocument.create!(submitter_id:, sha256: Digest::SHA256.hexdigest(SecureRandom.hex)).id
  end

  it 'is swept on the second walk rather than entombed over', sidekiq: :inline do
    submitter = submitter!
    landed = nil

    # delete_account_rows! runs after the documents have been deleted in this
    # pass, which is exactly where the straggler lands.
    allow(Accounts::Purge).to receive(:delete_account_rows!).and_wrap_original do |method, record, *rest|
      landed ||= insert_straggler!(submitter.id)

      method.call(record, *rest)
    end

    expect(Accounts::Purge.call(account)).to eq(:purged)

    expect(landed).to be_present
    expect(CompletedDocument.where(id: landed).count).to eq(0)
  end

  it 'refuses to entomb the account when one lands during the second walk too', sidekiq: :inline do
    submitter = submitter!

    allow(Accounts::Purge).to receive(:delete_account_rows!).and_wrap_original do |method, record, *rest|
      insert_straggler!(submitter.id)

      method.call(record, *rest)
    end
    allow(OperatorAlert).to receive(:deliver).and_call_original

    expect { Accounts::Purge.call(account) }
      .to raise_error(Accounts::Purge::Refused, /completed_documents=/)

    expect(account.reload.purged_at).to be_nil
    expect(OperatorAlert).to have_received(:deliver)
      .with(hash_including(subject: 'Account purge did not empty the account'))
  end

  # The count itself, asked directly: it is made against submitter ids written
  # down BEFORE the walk, so it cannot read zero once the submitters are gone.
  it 'is counted against submitter ids captured before the walk' do
    submitter = submitter!
    census = Accounts::Purge.census_for([account])

    expect(census[:owners]['Submitter']).to include(submitter.id)

    insert_straggler!(submitter.id)

    expect(Accounts::Purge.remaining_rows([account], census)['completed_documents']).to eq(1)

    # And now the walk takes the parent, which is where the old count went
    # blind: no submitter left to name, so the subquery was empty.
    SubmissionEvent.where(submitter_id: submitter.id).delete_all
    Submitter.where(id: submitter.id).delete_all

    expect(Accounts::Purge.remaining_rows([account], census)['completed_documents']).to eq(1)
  end
end

# C6: what the testing-sandbox rule actually is. The sandbox is not available
# to customer accounts at all (D57), and customers are the only accounts that
# are ever purged — so no customer's dormancy clock depends on this today.
# What the code really does is read the CHILD account's own last-used stamp
# into the parent's clock, and that is what this proves.
RSpec.describe 'The last-used stamp of a testing sandbox', type: :request do
  it "reads the child account's last_active_at into the parent's clock" do
    parent = create(:account, :with_testing_account, created_at: 3.years.ago)
    child = parent.testing_accounts.sole

    create(:user, account: parent, created_at: 3.years.ago, current_sign_in_at: 13.months.ago)

    expect(Accounts::Retention.used_at(parent)).to be_nil
    expect(Accounts::Retention.dormant?(parent)).to be(true)

    stamped = 2.days.ago

    child.update_columns(last_active_at: stamped)

    expect(Accounts::Retention.used_at(parent)).to be_within(1.second).of(stamped)
    expect(Accounts::Retention.last_activity_at(parent)).to be_within(1.second).of(stamped)
    expect(Accounts::Retention.dormant?(parent.reload)).to be(false)
  end
end
