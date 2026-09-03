# frozen_string_literal: true

# Stripe is the source of truth for who is paying. Everything below is driven
# through the REAL doors — a signed POST to /stripe/webhooks, the Sidekiq job
# that drains behind it, the nightly reconciliation, the rake tasks — against
# fixtures captured from the live EsignCenter test account with the Stripe CLI
# (spec/fixtures/stripe/, see docs/billing.md). Nothing here hand-writes a
# Stripe object except where a state the CLI cannot easily produce is needed,
# and those cases change only `status` / `cancel_at_period_end` on a real
# capture and say so.
#
# The two actors in the fixtures:
#   A  sub_1UBSbL…AD6ynIIK / cus_VBqHCUoJle1zGV — trialing → active → canceling → canceled
#   B  sub_1UBSds…s81X4tCG / cus_VBqKHh0NHYmvT1 — active → past_due → active (real test clock)
RSpec.describe 'Stripe billing', type: :request do
  let(:subscription_a) { 'sub_1UBSbL4rEeOqtLcXAD6ynIIK' }
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:api_headers) { { 'x-auth-token': user.access_token.token } }
  let(:customer_a) { 'cus_VBqHCUoJle1zGV' }
  let(:subscription_b) { 'sub_1UBSds4rEeOqtLcXs81X4tCG' }
  let(:customer_b) { 'cus_VBqKHh0NHYmvT1' }
  # The customer the `stripe trigger invoice.payment_failed` fixture made: no
  # account here owns it, which is exactly what makes it the unknown case.
  let(:customer_unknown) { 'cus_VBqJXVDDFKe0Zk' }

  let(:webhook_secret) { 'whsec_testsecret' }
  let(:fixture_price) { 'price_1UAt8N4rEeOqtLcX1amJxYdZ' }

  stash_env(*StripeBilling::CONFIG_KEYS.keys, 'BILLING_ENABLED')

  before do
    ENV['STRIPE_SECRET_KEY'] = 'sk_test_fake'
    ENV['STRIPE_PUBLISHABLE_KEY'] = 'pk_test_fake'
    ENV['STRIPE_WEBHOOK_SECRET'] = webhook_secret
    ENV['STRIPE_PRICE_ID'] = fixture_price
    ENV['STRIPE_PORTAL_CONFIGURATION_ID'] = 'bpc_test'
    ENV['BILLING_ENABLED'] = 'true'
  end

  def fixture_body(name)
    Rails.root.join("spec/fixtures/stripe/#{name}.json").read
  end

  def fixture_json(name)
    JSON.parse(fixture_body(name))
  end

  # Signs a captured event body exactly the way Stripe does and posts the raw
  # bytes — the header is built from the wire format, not from any app helper,
  # so a change to how we verify cannot make this pass by accident.
  def post_stripe_event(name, secret: webhook_secret, body: nil, at: Time.now.utc)
    payload = body || fixture_body(name)
    signature = Stripe::Webhook::Signature.compute_signature(at, payload, secret)

    post stripe_webhooks_path, params: payload,
                               headers: { 'Stripe-Signature' => "t=#{at.to_i},v1=#{signature}",
                                          'CONTENT_TYPE' => 'application/json' }

    payload
  end

  # Built from a local so the pattern is not a frozen constant regexp.
  def subscription_url(id)
    %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{Regexp.escape(id)}}
  end

  def stub_subscription(id, fixture, overrides = {})
    body = fixture_json(fixture).merge(overrides.stringify_keys)

    stub_request(:get, subscription_url(id))
      .to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def drain_stripe_jobs
    ProcessStripeEventJob.drain
  end

  # Runs a rake task the way an operator does, from a clean slate each time
  # (a task Rake already invoked will not run again without reenable).
  def run_rake_task(name, *)
    Rails.application.load_tasks unless Rake::Task.task_defined?(name)

    Rake::Task[name].reenable
    Rake::Task[name].invoke(*)
  end

  # The row an account that has been through Checkout already has: linked to
  # the Stripe customer, not yet paid for anything.
  def cancelled_row(for_account: account, customer: customer_a)
    create(:account_subscription, account: for_account, access_state: 'cancelled', status: 'none',
                                  stripe_customer_id: customer)
  end

  describe 'POST /stripe/webhooks — the door' do
    it 'refuses a body it cannot prove came from Stripe and stores nothing' do
      post_stripe_event('event-customer.subscription.created-trialing', secret: 'whsec_someone_else')

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to be_blank
      expect(StripeEventInbox.count).to eq(0)
      expect(ProcessStripeEventJob.jobs).to be_empty
    end

    it 'refuses a signature outside the timestamp tolerance' do
      post_stripe_event('event-customer.subscription.created-trialing',
                        at: Time.now.utc - Stripe::Webhook::DEFAULT_TOLERANCE - 60)

      expect(response).to have_http_status(:bad_request)
      expect(StripeEventInbox.count).to eq(0)
    end

    it 'answers 503 when the app has no webhook secret to verify against' do
      ENV['STRIPE_WEBHOOK_SECRET'] = nil

      post_stripe_event('event-customer.subscription.created-trialing')

      expect(response).to have_http_status(:service_unavailable)
      expect(StripeEventInbox.count).to eq(0)
    end

    it 'stores the exact verified bytes, enqueues one job and acknowledges' do
      payload = post_stripe_event('event-customer.subscription.created-trialing')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('received' => true)

      inbox = StripeEventInbox.sole

      # Byte for byte, trailing newline and all: a stored event that no longer
      # verifies against its own signature would be worthless.
      expect(inbox.payload).to eq(payload)
      expect(inbox.payload.encoding).to eq(Encoding::UTF_8).or eq(Encoding::ASCII_8BIT)
      expect(inbox.stripe_event_id).to eq('evt_1UBSbM4rEeOqtLcXkeUpX06X')
      expect(inbox.event_type).to eq('customer.subscription.created')
      expect(inbox.api_version).to eq(fixture_json('event-customer.subscription.created-trialing')['api_version'])
      expect(inbox.status).to eq('pending')
      expect(inbox.stripe_created_at).to eq(Time.zone.at(1_788_411_016))
      expect(ProcessStripeEventJob.jobs.size).to eq(1)
    end

    it 'acknowledges a repeated delivery without a second row or a second job' do
      2.times { post_stripe_event('event-customer.subscription.created-trialing') }

      expect(response).to have_http_status(:ok)
      expect(StripeEventInbox.count).to eq(1)
      expect(ProcessStripeEventJob.jobs.size).to eq(1)
    end

    # The launch switch decides whether customers can reach the billing pages.
    # Stripe still has to be able to tell us a subscription changed, or the
    # app's idea of who is paying goes permanently wrong.
    it 'accepts and stores events while BILLING_ENABLED is off' do
      ENV['BILLING_ENABLED'] = 'false'

      post_stripe_event('event-customer.subscription.created-trialing')

      expect(response).to have_http_status(:ok)
      expect(StripeEventInbox.sole.status).to eq('pending')
      expect(ProcessStripeEventJob.jobs.size).to eq(1)
    end
  end

  describe 'the trial that a subscription event starts' do
    it 'writes the whole subscription onto the row and turns paid features on' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')

      expect(Entitlements.allowed?(account, :api)).to be(false)

      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      row.reload

      expect(row.access_state).to eq('trialing')
      expect(row.status).to eq('trialing')
      expect(row.stripe_status).to eq('trialing')
      expect(row.quantity).to eq(3)
      expect(row.stripe_subscription_id).to eq(subscription_a)
      expect(row.stripe_item_id).to eq('si_VBqHaGFRPKUSpk')
      expect(row.stripe_price_id).to eq(fixture_price)
      expect(row.stripe_product_id).to eq('prod_VBFd5yb6kKFsDB')
      expect(row.trial_end).to eq(Time.zone.at(1_789_620_615))
      expect(row.trial_used_at).to be_present
      expect(row.cancel_at_period_end).to be(false)
      expect(row.synced_at).to be_present
      expect(row.last_stripe_event_at).to eq(Time.zone.at(1_788_411_016))
      # In this API version the billing period lives on the subscription ITEM.
      expect(row.current_period_start).to eq(Time.zone.at(1_788_411_015))
      expect(row.current_period_end).to eq(Time.zone.at(1_789_620_615))

      expect(StripeEventInbox.sole).to have_attributes(status: 'processed', attempts: 1,
                                                       account_id: account.id, last_error: nil)
      expect(StripeEventInbox.sole.processed_at).to be_present

      expect(Plans.key_for(account)).to eq(Plans::PAID)
      expect(Entitlements.allowed?(account, :api)).to be(true)

      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:ok)
    end

    it 'never hands out a second trial: trial_used_at survives a later subscription without one' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      first_stamp = row.reload.trial_used_at

      expect(first_stamp).to be_present

      stub_subscription(subscription_a, 'subscription-canceled', 'trial_end' => nil)
      post_stripe_event('event-customer.subscription.deleted')
      drain_stripe_jobs

      expect(row.reload.trial_used_at).to eq(first_stamp)
    end
  end

  describe 'out-of-order delivery' do
    # The event is only a trigger; the object Stripe returns now is the truth.
    # An `updated` that Stripe emitted BEFORE the cancellation must not undo it.
    it 'lets the current Stripe state win over an older event and never moves the stamp backwards' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      stub_subscription(subscription_a, 'subscription-canceled')
      post_stripe_event('event-customer.subscription.deleted')
      drain_stripe_jobs

      expect(row.reload.access_state).to eq('cancelled')
      expect(row.last_stripe_event_at).to eq(Time.zone.at(1_788_411_093))
      # A downgrade never purges: the ids stay so the history stays readable.
      expect(row.stripe_subscription_id).to eq(subscription_a)
      expect(row.stripe_customer_id).to eq(customer_a)

      older = fixture_json('event-customer.subscription.updated-active')

      expect(older['created']).to be < 1_788_411_093

      requests = 0
      stub_request(:get, subscription_url(subscription_a))
        .to_return do
          requests += 1
          { status: 200, body: fixture_body('subscription-canceled'),
            headers: { 'Content-Type' => 'application/json' } }
        end

      post_stripe_event('event-customer.subscription.updated-active')
      drain_stripe_jobs

      # It still re-fetched — that is what makes order stop mattering.
      expect(requests).to eq(1)
      expect(row.reload.access_state).to eq('cancelled')
      expect(row.last_stripe_event_at).to eq(Time.zone.at(1_788_411_093))

      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'an event for a customer nobody owns' do
    it 'is recorded, reported once and never creates a subscription' do
      cancelled_row

      allow(ErrorReport).to receive(:warning)

      expect { post_stripe_event('event-invoice.payment_failed-no_subscription') }
        .not_to change(AccountSubscription, :count)

      expect(response).to have_http_status(:ok)

      drain_stripe_jobs

      expect(ErrorReport).to have_received(:warning)
        .with(/matched no account/, hash_including(:stripe_event_id))

      inbox = StripeEventInbox.sole

      expect(inbox.status).to eq('ignored')
      expect(inbox.last_error).to eq('unknown customer')
      expect(inbox.account_id).to be_nil
      expect(fixture_json('event-invoice.payment_failed-no_subscription')['data']['object']['customer'])
        .to eq(customer_unknown)
    end

    it 'stores an event type it has no handler for and marks it ignored' do
      body = fixture_json('event-customer.subscription.created-trialing')
                          .merge('type' => 'radar.early_fraud_warning.created').to_json

      post_stripe_event(nil, body:)
      drain_stripe_jobs

      expect(StripeEventInbox.sole).to have_attributes(
        status: 'ignored', event_type: 'radar.early_fraud_warning.created'
      )
      expect(StripeEventInbox.sole.last_error).to include('unhandled event type')
    end
  end

  describe 'a second subscription for a customer that already has one' do
    # TODO: (CTO): swap this for a real subscription-mode
    # checkout.session.completed capture from the dev-stack Playwright walk —
    # `stripe trigger checkout.session.completed` only produces a PAYMENT-mode
    # session (asserted below), so the duplicate is driven here through the
    # second `customer.subscription.created` that a repeated Checkout also
    # emits. The protection itself is not checkout-specific by design.
    it 'is cancelled at Stripe on the spot and the account keeps the one it had' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(row.reload.access_state).to eq('trialing')

      cancel_call = stub_request(:delete, "https://api.stripe.com/v1/subscriptions/#{subscription_b}")
                    .to_return(status: 200, body: fixture_body('subscription-canceled'),
                               headers: { 'Content-Type' => 'application/json' })

      duplicate = fixture_json('event-customer.subscription.created-active')

      expect(duplicate['data']['object']['id']).to eq(subscription_b)

      duplicate['data']['object']['customer'] = customer_a

      allow(OperatorAlert).to receive(:deliver).and_return(true)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(OperatorAlert).to have_received(:deliver).with(hash_including(:subject, :body))
      expect(cancel_call).to have_been_requested
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('trialing')
      expect(StripeEventInbox.order(:id).last)
        .to have_attributes(status: 'processed', last_error: 'duplicate subscription cancelled')
    end

    # Stripe then tells us that duplicate ended. Acting on that would ask
    # Stripe to cancel something already gone, forever.
    it 'takes no action when Stripe reports the duplicate it already cancelled has ended' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      farewell = fixture_json('event-customer.subscription.deleted')
      farewell['id'] = 'evt_duplicate_farewell'
      farewell['data']['object']['id'] = subscription_b
      farewell['data']['object']['customer'] = customer_a

      post_stripe_event(nil, body: farewell.to_json)
      drain_stripe_jobs

      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(row.reload.access_state).to eq('trialing')
      expect(row.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.find_by(stripe_event_id: 'evt_duplicate_farewell'))
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::FOREIGN_SUBSCRIPTION)
    end

    it 'ignores a payment-mode Checkout session outright' do
      cancelled_row

      post_stripe_event('event-checkout.session.completed-payment')
      drain_stripe_jobs

      expect(fixture_json('event-checkout.session.completed-payment')['data']['object']['mode']).to eq('payment')
      expect(StripeEventInbox.sole).to have_attributes(status: 'ignored')
      expect(StripeEventInbox.sole.last_error).to include('mode payment')
    end
  end

  describe 'a failed payment and the recovery after it' do
    let!(:row) do
      create(:account_subscription, account:, access_state: 'active', status: 'active',
                                    stripe_customer_id: customer_b, stripe_subscription_id: subscription_b,
                                    quantity: 2)
    end

    it 'starts the dunning clock, keeps paid access, and stops the clock when the invoice is paid' do
      stub_subscription(subscription_b, 'subscription-past_due')

      # The invoice names its subscription under parent.subscription_details in
      # this API version — that shape is what the resolver has to read.
      expect(fixture_json('event-invoice.payment_failed')['data']['object']
               .dig('parent', 'subscription_details', 'subscription')).to eq(subscription_b)

      post_stripe_event('event-invoice.payment_failed')
      drain_stripe_jobs

      row.reload

      expect(row.access_state).to eq('past_due')
      expect(row.stripe_status).to eq('past_due')
      expect(row.past_due_since).to be_present

      # past_due is still paid access: a late renewal does not take the
      # product away while Stripe is still trying the card.
      expect(Entitlements.allowed?(account, :api)).to be(true)

      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:ok)

      first_clock = row.past_due_since

      post_stripe_event('event-invoice.payment_failed', at: Time.now.utc + 1)

      # A repeated delivery of the same event changes nothing at all.
      expect(row.reload.past_due_since).to eq(first_clock)

      stub_subscription(subscription_b, 'subscription-active-recovered')
      post_stripe_event('event-invoice.paid-recovered')
      drain_stripe_jobs

      row.reload

      expect(row.access_state).to eq('active')
      expect(row.past_due_since).to be_nil
    end

    # `unpaid` is where Stripe gives up. The capture is the real past_due
    # subscription with only `status` changed — producing a genuine unpaid one
    # needs a dunning setting the account does not use.
    it 'takes paid features away once Stripe gives up on the payment' do
      create(:account_config, account:, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      stub_subscription(subscription_b, 'subscription-past_due', 'status' => 'unpaid')

      post_stripe_event('event-invoice.payment_failed')
      drain_stripe_jobs

      row.reload

      expect(row.access_state).to eq('suspended')
      expect(row.stripe_status).to eq('unpaid')
      expect(row.past_due_since).to be_nil
      expect(Plans.key_for(account)).to eq(Plans::FREE)
      expect(Accounts.branding_removed?(account)).to be(false)

      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe StripeBilling::SubscriptionSync do
    # Every row of the state table in docs/billing.md, over real captures with
    # only `status` / `cancel_at_period_end` changed.
    {
      %w[trialing false] => 'trialing',
      %w[trialing true] => 'canceling',
      %w[active false] => 'active',
      %w[active true] => 'canceling',
      %w[past_due false] => 'past_due',
      %w[past_due true] => 'past_due',
      %w[unpaid false] => 'suspended',
      %w[unpaid true] => 'suspended',
      %w[paused false] => 'suspended',
      %w[paused true] => 'suspended',
      %w[incomplete false] => 'cancelled',
      %w[incomplete true] => 'cancelled',
      %w[incomplete_expired false] => 'cancelled',
      %w[canceled false] => 'cancelled',
      %w[canceled true] => 'cancelled'
    }.each do |(status, cancel_flag), expected|
      it "reads Stripe #{status} (cancel_at_period_end=#{cancel_flag}) as #{expected}" do
        subscription = JSON.parse(Rails.root.join('spec/fixtures/stripe/subscription-active.json').read)
                           .merge('status' => status, 'cancel_at_period_end' => cancel_flag == 'true')

        expect(described_class.access_state_for(subscription)).to eq(expected)
      end
    end

    it 'never grants paid access on a status it does not recognise' do
      subscription = fixture_json('subscription-active').merge('status' => 'something_new')

      expect(described_class.access_state_for(subscription)).to eq('cancelled')
      expect(Plans::PAID_ACCESS_STATES).not_to include('cancelled')
    end

    it 'never lets a row drop below one seat' do
      subscription = fixture_json('subscription-active')
      subscription['items']['data'][0]['quantity'] = 0

      expect(described_class.quantity_for(subscription)).to eq(1)
    end

    it 'covers every access state the app knows' do
      expect(described_class::STATE_BY_STRIPE_STATUS.values.uniq + ['canceling'])
        .to match_array(Plans::ACCESS_STATES)
    end
  end

  describe ProcessStripeEventJob do
    it 'records the failure, re-raises so Sidekiq retries, and succeeds on a later run' do
      row = cancelled_row

      stub_request(:get, subscription_url(subscription_a))
        .to_return(status: 500, body: '{"error":{"message":"Stripe is having a bad day"}}',
                   headers: { 'Content-Type' => 'application/json' })

      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole

      expect { described_class.new.perform(inbox.id) }.to raise_error(Stripe::APIError)

      inbox.reload

      expect(inbox.status).to eq('failed')
      expect(inbox.attempts).to eq(1)
      expect(inbox.last_error).to include('Stripe')
      expect(row.reload.access_state).to eq('cancelled')

      stub_subscription(subscription_a, 'subscription-trialing')

      described_class.new.perform(inbox.id)

      expect(inbox.reload.status).to eq('processed')
      expect(inbox.attempts).to eq(2)
      expect(inbox.last_error).to be_nil
      expect(row.reload.access_state).to eq('trialing')
    end

    it 'tells the operator when Sidekiq has given up on an event' do
      cancelled_row
      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole
      inbox.update!(status: 'failed', attempts: 5, last_error: 'Stripe::APIError: boom')
      error = Stripe::APIError.new('boom')

      allow(ErrorReport).to receive(:error)
      allow(OperatorAlert).to receive(:deliver).and_return(true)

      described_class.sidekiq_retries_exhausted_block.call({ 'args' => [inbox.id] }, error)

      expect(ErrorReport).to have_received(:error)
        .with(error, hash_including(stripe_event_id: inbox.stripe_event_id))
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(subject: "Stripe event #{inbox.stripe_event_id} failed 5 times"))
    end

    it 'leaves a row it already decided alone' do
      cancelled_row
      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole
      inbox.update!(status: 'processed', processed_at: Time.current)

      expect { described_class.new.perform(inbox.id) }.not_to(change { inbox.reload.attempts })
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
    end
  end

  describe StripeReconciliationJob do
    it 'repairs a row Stripe disagrees with, leaves a matching one alone, and alerts once' do
      drifted = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                              stripe_customer_id: customer_a,
                                              stripe_subscription_id: subscription_a, quantity: 3)
      agreeing_account = create(:account)
      agreeing = create(:account_subscription, account: agreeing_account, access_state: 'past_due',
                                               status: 'past_due', stripe_customer_id: customer_b,
                                               stripe_subscription_id: subscription_b, quantity: 2)
      StripeBilling::SubscriptionSync.apply!(agreeing, JSON.parse(fixture_body('subscription-past_due')))
      agreeing.reload

      stub_subscription(subscription_a, 'subscription-canceled')
      stub_subscription(subscription_b, 'subscription-past_due')

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }

      report = described_class.new.perform

      expect(drifted.reload.access_state).to eq('cancelled')
      expect(report.repaired.size).to eq(1)
      expect(report.repaired.sole).to include(account_id: account.id, was: 'active', now: 'cancelled')
      expect(agreeing.reload.access_state).to eq('past_due')
      expect(alerts.size).to eq(1)
      expect(alerts.sole[:body]).to include("account #{account.id}: active -> cancelled")
    end

    it 'never touches a row the operator granted by hand' do
      manual = create(:account_subscription, account:, access_state: 'active', status: 'manual',
                                             stripe_subscription_id: subscription_a)

      stub_subscription(subscription_a, 'subscription-canceled')

      described_class.new.perform

      expect(manual.reload.access_state).to eq('active')
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
    end

    it 're-enqueues events stuck in flight and failed events with retries left' do
      cancelled_row
      post_stripe_event('event-customer.subscription.created-trialing')

      stuck = StripeEventInbox.sole
      stuck.update_columns(status: 'processing', updated_at: 20.minutes.ago)

      failed = StripeEventInbox.create!(stripe_event_id: 'evt_failed', event_type: 'invoice.paid',
                                        payload: '{}', status: 'failed', attempts: 2)
      exhausted = StripeEventInbox.create!(stripe_event_id: 'evt_exhausted', event_type: 'invoice.paid',
                                           payload: '{}', status: 'failed', attempts: 5)

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      ProcessStripeEventJob.jobs.clear

      report = described_class.new.perform

      enqueued = ProcessStripeEventJob.jobs.map { |job| job['args'].first }

      expect(enqueued).to contain_exactly(stuck.id, failed.id)
      expect(enqueued).not_to include(exhausted.id)
      expect(report.requeued).to eq(2)
    end

    it 'keeps going when Stripe fails on one account' do
      broken = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                             stripe_subscription_id: subscription_a)
      other_account = create(:account)
      repairable = create(:account_subscription, account: other_account, access_state: 'active', status: 'active',
                                                 stripe_subscription_id: subscription_b, quantity: 2)

      stub_request(:get, subscription_url(subscription_a))
        .to_return(status: 404, body: '{"error":{"message":"No such subscription"}}',
                   headers: { 'Content-Type' => 'application/json' })
      stub_subscription(subscription_b, 'subscription-past_due')

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:error)
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(report.errors.size).to eq(1)
      expect(broken.reload.access_state).to eq('active')
      expect(repairable.reload.access_state).to eq('past_due')
    end
  end

  describe 'an account billed through its parent' do
    let(:parent) { create(:account) }
    let(:child) do
      Account.create!(name: 'Team', locale: 'en-US', timezone: 'UTC',
                      linked_account_account: AccountLinkedAccount.new(account_type: :linked, account: parent))
    end

    it 'follows the parent subscription when a Stripe event lands on the parent customer' do
      create(:account_subscription, account: parent, access_state: 'cancelled', status: 'none',
                                    stripe_customer_id: customer_a)

      expect(Plans.billing_account(child)).to eq(parent)
      expect(Plans.key_for(child)).to eq(Plans::FREE)

      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      child.reload

      expect(Plans.key_for(child)).to eq(Plans::PAID)
      expect(Entitlements.allowed?(child, :api)).to be(true)
    end

    it 'writes the parent row when the operator grants the child by hand' do
      child

      expect { run_rake_task('plans:grant', child.id.to_s, '4') }
        .to output(/Billing account is ##{parent.id} \(parent of ##{child.id}\)/).to_stdout

      expect(child.reload.account_subscription).to be_nil
      expect(parent.reload.account_subscription).to have_attributes(access_state: 'active', quantity: 4,
                                                                    status: 'manual')
      expect(Plans.key_for(child)).to eq(Plans::PAID)
    end

    it 'refuses to grant an internal account' do
      internal = create(:account, :internal)

      expect { run_rake_task('plans:grant', internal.id.to_s) }
        .to raise_error(SystemExit).and output(/always on the internal plan/).to_stderr
    end
  end

  describe StripeBilling::ConfigGuard do
    around do |example|
      original = Rails.env

      example.run
    ensure
      Rails.env = original
    end

    it 'refuses to boot production with a key missing' do
      ENV['STRIPE_PORTAL_CONFIGURATION_ID'] = nil
      Rails.env = 'production'

      expect { described_class.check! }
        .to raise_error(/STRIPE_PORTAL_CONFIGURATION_ID is not set/)
    end

    it 'refuses to boot production with a value that is not the thing it names' do
      ENV['STRIPE_WEBHOOK_SECRET'] = 'sk_test_oops'
      ENV['STRIPE_SECRET_KEY'] = 'sk_live_realkey'
      Rails.env = 'production'

      expect { described_class.check! }
        .to raise_error(/STRIPE_WEBHOOK_SECRET does not look like a Stripe value.*whsec_/)
    end

    it 'refuses to run production against a test key' do
      Rails.env = 'production'

      expect { described_class.check! }.to raise_error(/test key but this is production/)
    end

    it 'only warns outside production' do
      ENV['STRIPE_PRICE_ID'] = nil

      allow(Rails.logger).to receive(:warn)

      Rails.env = 'development'

      expect { described_class.check! }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/STRIPE_PRICE_ID is not set/)
    end

    it 'says nothing at all while billing is switched off' do
      ENV['BILLING_ENABLED'] = 'false'
      ENV['STRIPE_SECRET_KEY'] = nil
      Rails.env = 'production'

      expect { described_class.check! }.not_to raise_error
    end
  end

  describe 'rake stripe:check' do
    def stub_price(overrides = {})
      body = { id: fixture_price, object: 'price', active: true, currency: 'usd', unit_amount: 1000,
               recurring: { interval: 'month', interval_count: 1 } }.merge(overrides)

      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/prices/})
        .to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    # What Stripe returns for a portal that lets a customer change their own
    # plan and seat count — the thing this app must never offer.
    def adjustable_products
      [{ product: 'prod_VBFd5yb6kKFsDB', prices: [fixture_price],
         adjustable_quantity: { enabled: true, minimum: 1, maximum: 100 } }]
    end

    def stub_portal(subscription_update_enabled: false)
      body = { id: 'bpc_test', object: 'billing_portal.configuration', active: true,
               features: { invoice_history: { enabled: true }, payment_method_update: { enabled: true },
                           subscription_cancel: { enabled: true, mode: 'at_period_end' },
                           subscription_update: {
                             enabled: subscription_update_enabled,
                             products: subscription_update_enabled ? adjustable_products : nil
                           } } }

      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/billing_portal/configurations/})
        .to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    def stub_endpoints(urls)
      body = { object: 'list', data: urls.map do |url|
        { id: 'we_1', object: 'webhook_endpoint', url:, status: 'enabled',
          enabled_events: StripeBilling::Checks::WEBHOOK_EVENTS }
      end }

      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/webhook_endpoints})
        .to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'passes when the price, the portal and the endpoint all match the manifest' do
      stub_price
      stub_portal
      stub_endpoints(['https://esign.example.com/stripe/webhooks'])

      rows = StripeBilling::Checks.rows

      expect(rows.pluck(:result).uniq).to eq(['PASS'])
      expect(StripeBilling::Checks.failed?(rows)).to be(false)
      expect { run_rake_task('stripe:check') }.to output(/stripe:check passed/).to_stdout
    end

    it 'fails when the Customer Portal would let a customer edit their own seats' do
      stub_price
      stub_portal(subscription_update_enabled: true)
      stub_endpoints(['https://esign.example.com/stripe/webhooks'])

      rows = StripeBilling::Checks.rows

      expect(StripeBilling::Checks.failed?(rows)).to be(true)
      expect(rows.find { |row| row[:name] == 'portal subscription_update off' }[:result]).to eq('FAIL')
      expect { run_rake_task('stripe:check') }.to raise_error(SystemExit).and output(/FAILED/).to_stderr
    end

    it 'fails when the price is no longer $10 a month' do
      stub_price(unit_amount: 1500)
      stub_portal
      stub_endpoints(['https://esign.example.com/stripe/webhooks'])

      rows = StripeBilling::Checks.rows

      expect(rows.find { |row| row[:name] == 'price amount' })
        .to include(result: 'FAIL', detail: '1500 (expected 1000)')
    end

    it 'warns rather than fails when no endpoint points at us (the dev stack forwards instead)' do
      stub_price
      stub_portal
      stub_endpoints(['https://someone-else.example.com/hooks'])

      rows = StripeBilling::Checks.rows

      expect(rows.find { |row| row[:name] == 'webhook endpoint' })
        .to include(result: 'WARN')
      expect(StripeBilling::Checks.failed?(rows)).to be(false)
    end

    it 'skips the portal check until the operator has created the configuration' do
      ENV['STRIPE_PORTAL_CONFIGURATION_ID'] = nil
      stub_price
      stub_endpoints([])

      rows = StripeBilling::Checks.rows

      expect(rows.find { |row| row[:name] == 'portal' }).to include(result: 'SKIP')
      expect(rows.find { |row| row[:name] == 'STRIPE_PORTAL_CONFIGURATION_ID' }).to include(result: 'FAIL')
    end

    it 'builds the portal exactly as the manifest describes it' do
      params = StripeBilling::Checks.portal_params

      expect(params.dig(:features, :subscription_update, :enabled)).to be(false)
      expect(params.dig(:features, :subscription_cancel))
        .to include(enabled: true, mode: 'at_period_end', proration_behavior: 'none')
      expect(params.dig(:features, :subscription_cancel, :cancellation_reason, :options).size).to eq(7)
      expect(params.dig(:features, :customer_update, :allowed_updates)).to eq(%w[email address name])
      expect(params[:default_return_url]).to end_with('/settings/billing')
      expect(params[:metadata]).to eq(esigncenter_manifest_version: '1')
    end
  end

  describe 'the API version the app is written against' do
    it 'is pinned on the client rather than inherited from the gem' do
      stub_subscription(subscription_a, 'subscription-trialing')

      StripeBilling.subscription_for(subscription_a)

      expect(a_request(:get, subscription_url(subscription_a))
               .with(headers: { 'Stripe-Version' => StripeBilling::API_VERSION })).to have_been_made
    end
  end
end
