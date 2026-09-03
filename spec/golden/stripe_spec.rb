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
RSpec.describe 'Stripe billing', type: :request do # rubocop:disable RSpec/MultipleDescribes
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

  # The retrieve is stubbed on the EXACT subscription id and on the expansion
  # the app asks for: an unexpanded price would come back as a bare id string
  # and the mapping would have nothing to read.
  def stub_subscription(id, fixture, overrides = {}, expand: StripeBilling::SUBSCRIPTION_EXPAND)
    body = fixture_json(fixture).merge(overrides.stringify_keys)

    stub_request(:get, subscription_url(id))
      .with(query: hash_including('expand' => expand))
      .to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  # A DUPLICATE is fetched with its latest invoice and that invoice's
  # payments, because the app has to know what it already charged.
  def stub_duplicate(id, fixture, overrides = {}, invoice: unpaid_invoice(id))
    stub_subscription(id, fixture, overrides.merge('id' => id, 'latest_invoice' => invoice),
                      expand: StripeBilling::Linker::DUPLICATE_EXPAND)
  end

  # And cancelled with the same expansion, so the answer says what it charged
  # — stamped with our marker, so a later look can tell we did it.
  def stub_cancel(id, fixture = 'subscription-canceled', overrides = {}, invoice: unpaid_invoice(id))
    stub_request(:delete, subscription_url(id))
      .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND,
                                  'cancellation_details' => { 'comment' => StripeBilling::DUPLICATE_CANCEL_MARKER }))
      .to_return(status: 200, body: fixture_json(fixture).merge(overrides.stringify_keys)
                                                          .merge('id' => id, 'latest_invoice' => invoice).to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  # A trial's first invoice: $0, no payment behind it.
  def unpaid_invoice(subscription_id)
    { id: "in_trial_#{subscription_id}", object: 'invoice', amount_paid: 0, currency: 'usd',
      payments: { object: 'list', data: [] } }
  end

  # An invoice that collected money, settled by one PaymentIntent — the shape
  # this API version uses (`payments`, not a top-level `payment_intent`).
  def paid_invoice(subscription_id, amount:, payment_intent: "pi_#{subscription_id}")
    { id: "in_paid_#{subscription_id}", object: 'invoice', amount_paid: amount, currency: 'usd',
      payments: { object: 'list',
                  data: [{ object: 'invoice_payment', status: 'paid',
                           payment: { type: 'payment_intent', payment_intent: } }] } }
  end

  def stub_refund(payment_intent, amount:)
    stub_request(:post, 'https://api.stripe.com/v1/refunds')
      .with(body: hash_including('payment_intent' => payment_intent, 'reason' => 'duplicate'))
      .to_return(status: 200, body: { id: "re_#{payment_intent}", object: 'refund', amount:, currency: 'usd' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  # A subscription as Stripe's LIST returns it: ours when it carries an item
  # on our price, a stranger's when it sits on some other price.
  def listed_subscription(id, status, price: fixture_price, created: 1_788_411_000, metadata: {})
    { id:, object: 'subscription', status:, created:, metadata:,
      items: { object: 'list', data: [{ id: "si_#{id}", object: 'subscription_item', price:, quantity: 1 }] } }
  end

  # What Stripe answers when the app asks which subscriptions a customer has.
  # `entries` are ids → statuses (on our price) or ready-made list rows.
  def stub_subscription_list(customer_id, entries = {}, has_more: false, starting_after: nil)
    data = entries.map { |id, status| status.is_a?(Hash) ? status : listed_subscription(id, status) }
    query = { 'customer' => customer_id, 'status' => 'all', 'limit' => '100' }
    query['starting_after'] = starting_after if starting_after

    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions\?})
      .with(query: hash_including(query))
      .to_return(status: 200, body: { object: 'list', data:, has_more: }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
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

      stub_subscription(subscription_a, 'subscription-canceled', { 'trial_end' => nil })
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
        .with(query: hash_including('expand' => ['items.data.price']))
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

    it 'never applies anything to an internal account, however it got a customer id' do
      internal = create(:account, :internal)
      row = create(:account_subscription, account: internal, access_state: 'cancelled', status: 'none',
                                          stripe_customer_id: customer_a)

      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(row.reload.access_state).to eq('cancelled')
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::NON_CUSTOMER_ACCOUNT)
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

  # The primary purchase path, over a real capture: the SUBSCRIPTION-mode
  # checkout.session.completed that `stripe listen` delivered during the
  # dev-stack Playwright walk, and the subscription that session bought,
  # fetched from the same test account (subscription-trialing-checkout.json —
  # trialing, one seat). `stripe trigger` cannot make this event: it only
  # produces a PAYMENT-mode session (see the last example below).
  #   C  sub_1UBWMO…C8lEPjHc / cus_VBu7yLiYn0WQS8, reference "221"
  #
  # `handle_checkout` resolves the account through the session's
  # client_reference_id FIRST — the id our own Checkout stamps the session
  # with — and only falls back to the subscription/customer lookup when that
  # reference names no billable account. Both doors are driven below.
  describe 'the Checkout that sells the subscription' do
    let(:subscription_c) { 'sub_1UBWMO4rEeOqtLcXC8lEPjHc' }
    let(:customer_c) { 'cus_VBu7yLiYn0WQS8' }
    let(:checkout_event) { 'event-checkout.session.completed-subscription' }

    # The capture was made by the dev-stack account (id 221); rewriting the
    # reference to this account's id is exactly what its own Checkout writes.
    def checkout_body(reference)
      body = fixture_json(checkout_event)
      body['data']['object']['client_reference_id'] = reference.to_s
      body.to_json
    end

    it 'attaches the subscription the session bought and turns paid features on' do
      row = cancelled_row(customer: customer_c)
      stub_subscription(subscription_c, 'subscription-trialing-checkout')

      expect(fixture_json(checkout_event)['data']['object'])
        .to include('mode' => 'subscription', 'client_reference_id' => '221',
                    'customer' => customer_c, 'subscription' => subscription_c)
      expect(Entitlements.allowed?(account, :api)).to be(false)

      post_stripe_event(nil, body: checkout_body(account.id))
      drain_stripe_jobs

      row.reload

      expect(row.access_state).to eq('trialing')
      expect(row.status).to eq('trialing')
      expect(row.stripe_status).to eq('trialing')
      expect(row.stripe_subscription_id).to eq(subscription_c)
      expect(row.stripe_customer_id).to eq(customer_c)
      expect(row.stripe_item_id).to eq('si_VBuAYkwdZLCHfW')
      expect(row.stripe_price_id).to eq(fixture_price)
      # One seat: the walk bought a single-seat trial, and the capture says so.
      expect(row.quantity).to eq(1)
      expect(row.trial_end).to eq(Time.zone.at(1_789_635_063))
      expect(row.trial_used_at).to be_present
      expect(row.synced_at).to be_present

      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'processed', account_id: account.id, last_error: nil,
                            event_type: 'checkout.session.completed')
      expect(Plans.key_for(account)).to eq(Plans::PAID)
      expect(Entitlements.allowed?(account, :api)).to be(true)

      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:ok)
    end

    # The reference is what resolves it here: no row in the database holds
    # this customer, so the customer lookup would have found nothing at all.
    # This is the first purchase an account ever makes.
    it 'creates the row for the account the session names, with no row to find by customer' do
      stub_subscription(subscription_c, 'subscription-trialing-checkout')

      expect(AccountSubscription.find_by(stripe_customer_id: customer_c)).to be_nil

      post_stripe_event(nil, body: checkout_body(account.id))
      drain_stripe_jobs

      row = AccountSubscription.sole

      expect(row.account_id).to eq(account.id)
      expect(row.access_state).to eq('trialing')
      expect(row.stripe_subscription_id).to eq(subscription_c)
      expect(row.stripe_customer_id).to eq(customer_c)
      expect(row.quantity).to eq(1)
      expect(Plans.key_for(account)).to eq(Plans::PAID)
    end

    # And the fallback half: a reference that names no account — a session
    # from another environment, an account since deleted — still resolves
    # through the customer the session was paid by.
    it 'falls back to the customer on the session when the reference names no account' do
      row = cancelled_row(customer: customer_c)
      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      unknown_reference = Account.maximum(:id).to_i + 1

      expect(Account.find_by(id: unknown_reference)).to be_nil

      post_stripe_event(nil, body: checkout_body(unknown_reference))
      drain_stripe_jobs

      row.reload

      expect(row.access_state).to eq('trialing')
      expect(row.stripe_subscription_id).to eq(subscription_c)
      expect(row.trial_used_at).to be_present
      expect(StripeEventInbox.sole).to have_attributes(status: 'processed', account_id: account.id)
      expect(Plans.key_for(account)).to eq(Plans::PAID)
    end
  end

  describe 'a second subscription for a customer that already has one' do
    # A repeated Checkout is driven here through the second
    # `customer.subscription.created` it also emits: the protection is not
    # checkout-specific by design, and the same Linker decision stands behind
    # the checkout door proved above.
    it 'is cancelled at Stripe on the spot and the account keeps the one it had' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(row.reload.access_state).to eq('trialing')

      # The duplicate is looked at before it is touched, and is a trial: its
      # first invoice collected nothing, so there is nothing to refund.
      stub_duplicate(subscription_b, 'subscription-active')
      cancel_call = stub_cancel(subscription_b)

      duplicate = fixture_json('event-customer.subscription.created-active')

      expect(duplicate['data']['object']['id']).to eq(subscription_b)

      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(alerts.sole[:body]).to include('Nothing was charged twice')
      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('trialing')
      expect(StripeEventInbox.order(:id).last)
        .to have_attributes(status: 'processed', last_error: 'duplicate subscription cancelled')
    end

    # G5: an account whose trial is spent pays its first invoice DURING
    # Checkout, before any webhook. Cancelling the duplicate is then only half
    # the job: the money it took has to go back, and the operator is told
    # which refund did it.
    it 'refunds what a paid duplicate already charged, and says so' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      invoice = paid_invoice(subscription_b, amount: 3000)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      refund_call = stub_refund("pi_#{subscription_b}", amount: 3000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(refund_call).to have_been_requested.once
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(headers: { 'Idempotency-Key' => "refund-duplicate-#{invoice[:id]}" })).to have_been_made
      expect(alerts.sole[:body]).to include("charge of $30.00 was refunded (re_pi_#{subscription_b})")
      expect(ErrorReport).to have_received(:warning)
        .with(/Cancelled duplicate/, hash_including(refund_id: "re_pi_#{subscription_b}"))
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')
    end

    it 'fails loudly, rather than keeping the money quietly, when the refund cannot be made' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      invoice = paid_invoice(subscription_b, amount: 3000)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_request(:post, 'https://api.stripe.com/v1/refunds')
        .to_return(status: 400, body: { error: { type: 'invalid_request_error', code: 'charge_already_refunded',
                                                 message: 'Charge has already been refunded' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }.to raise_error(Stripe::InvalidRequestError)
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      expect(inbox.reload.status).to eq('failed')
    end

    # H1: a delayed `updated` about an OLD subscription that ended on its own
    # — the customer's previous, legitimate renewal — is not a duplicate. It
    # is already over when looked at and carries no marker of ours, so
    # nothing is cancelled and, above all, nothing is refunded.
    it 'refunds nothing for a stale event about a subscription that ended on its own' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      stub_subscription(subscription_a, 'subscription-active')

      invoice = paid_invoice(subscription_b, amount: 3000)
      stub_duplicate(subscription_b, 'subscription-canceled', invoice:)
      stub_refund("pi_#{subscription_b}", amount: 3000)

      expect(fixture_json('subscription-canceled').dig('cancellation_details', 'comment')).to be_nil

      stale = fixture_json('event-customer.subscription.created-active')
      stale['type'] = 'customer.subscription.updated'
      stale['data']['object']['customer'] = customer_a

      allow(ErrorReport).to receive(:info)
      allow(OperatorAlert).to receive(:deliver).and_return(true)

      post_stripe_event(nil, body: stale.to_json)
      drain_stripe_jobs

      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(OperatorAlert).not_to have_received(:deliver)
      expect(ErrorReport).to have_received(:info).with(/stale subscription #{subscription_b} ignored/, anything)
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::FOREIGN_SUBSCRIPTION)
    end

    # H1, the retry half: a duplicate WE cancelled (our marker is on it)
    # whose refund step failed last time is still owed its refund, and gets
    # it exactly once.
    it 'finishes the refund of a duplicate it cancelled earlier, and only that' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      stub_subscription(subscription_a, 'subscription-active')

      invoice = paid_invoice(subscription_b, amount: 3000)
      marked = { 'cancellation_details' => { 'comment' => StripeBilling::DUPLICATE_CANCEL_MARKER,
                                             'reason' => 'cancellation_requested' } }
      stub_duplicate(subscription_b, 'subscription-canceled', marked, invoice:)
      refund_call = stub_refund("pi_#{subscription_b}", amount: 3000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(refund_call).to have_been_requested.once
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(headers: { 'Idempotency-Key' => "refund-duplicate-#{invoice[:id]}" })).to have_been_made
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'processed', last_error: ProcessStripeEventJob::DUPLICATE_SUBSCRIPTION)
    end

    # H6: two live subscriptions of ours, both real, and the row happens to
    # hold the LATER one (they arrived out of order). The survivor policy —
    # not arrival order — decides: the earlier one is kept, the later one is
    # the duplicate, whichever the row held.
    it 'moves to the earlier subscription and cancels the later one it held, when both are live' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_b, quantity: 3)
      stub_subscription(subscription_b, 'subscription-active', { 'created' => 2_000 })
      stub_duplicate(subscription_a, 'subscription-trialing', { 'created' => 1_000 })
      stub_duplicate(subscription_b, 'subscription-active', { 'created' => 2_000 })
      cancel_call = stub_cancel(subscription_b)

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(cancel_call).to have_been_requested
      row.reload
      expect(row.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('trialing')
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'processed', last_error: ProcessStripeEventJob::DUPLICATE_SUBSCRIPTION)
    end

    # G2: the row's cached columns say its subscription is over, but Stripe
    # says it is running (a lost `resumed` webhook). The cache is never the
    # basis for adopting: Stripe is asked about the row's OWN subscription,
    # and the newcomer is the duplicate.
    it 'asks Stripe about the subscription it holds rather than trusting a stale cancelled cache' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                          stripe_status: 'canceled', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)

      stub_subscription(subscription_a, 'subscription-active')
      stub_duplicate(subscription_b, 'subscription-active')
      cancel_call = stub_cancel(subscription_b)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(cancel_call).to have_been_requested
      row.reload
      expect(row.stripe_subscription_id).to eq(subscription_a)
      # And what Stripe said about its own subscription was written while in hand.
      expect(row.access_state).to eq('active')
    end

    # G3: a subscription on the customer that this app never sold — another
    # product, a dashboard experiment — is somebody's real purchase. It is
    # never cancelled as a "duplicate", and the job refuses rather than
    # guessing.
    it 'refuses to cancel a subscription that is not ours, however it arrived' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      foreign = fixture_json('subscription-active')
      foreign['items']['data'][0]['price']['id'] = 'price_other_product'
      foreign['metadata'] = {}
      stub_duplicate(subscription_b, 'subscription-active', foreign.slice('items', 'metadata'))

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }.to raise_error(ArgumentError, /not an EsignCenter/)
      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
    end

    it 'never adopts a stranger subscription onto a row that holds nothing' do
      row = cancelled_row
      foreign = fixture_json('subscription-trialing')
      foreign['items']['data'][0]['price']['id'] = 'price_other_product'
      foreign['metadata'] = {}
      stub_subscription(subscription_a, 'subscription-trialing', foreign.slice('items', 'metadata'))

      allow(ErrorReport).to receive(:warning)

      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(row.reload.stripe_subscription_id).to be_nil
      expect(row.access_state).to eq('cancelled')
      expect(ErrorReport).to have_received(:warning).with(/is not ours; left alone/, hash_including(:account_id))
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::FOREIGN_SUBSCRIPTION)
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

    # F5: only "it is already gone" may be swallowed. Any other refusal means
    # the duplicate may still be charging the customer, so the job has to
    # fail and be retried rather than record a cancellation that never was.
    it 'fails rather than pretending it cancelled a duplicate Stripe refused to cancel' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      stub_request(:delete, subscription_url(subscription_b))
        .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND))
        .to_return(status: 400,
                   body: { error: { type: 'invalid_request_error', code: 'parameter_invalid',
                                    message: 'Cannot cancel this subscription' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
      # Stripe still calls the duplicate live, so it is not "already gone".
      stub_duplicate(subscription_b, 'subscription-active')

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }.to raise_error(Stripe::InvalidRequestError)
      expect(inbox.reload.status).to eq('failed')
      expect(inbox.last_error).to include('InvalidRequestError')
    end

    # G10: "already gone" means Stripe SAID so — resource_missing, or a
    # retrieved status that is explicitly finished. A malformed answer with no
    # status is not a cancellation.
    it 'does not read a blank status as "already cancelled"' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      stub_request(:delete, subscription_url(subscription_b))
        .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND))
        .to_return(status: 400,
                   body: { error: { type: 'invalid_request_error', code: 'parameter_invalid',
                                    message: 'Cannot cancel this subscription' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
      retrieves = 0
      stub_request(:get, subscription_url(subscription_b))
        .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND))
        .to_return do
          retrieves += 1
          # Ours (the first look), then a body with no status at all (the "is it gone?" look).
          body = fixture_json('subscription-active').merge('id' => subscription_b)
          body['status'] = '' if retrieves > 1

          { status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
        end

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }.to raise_error(Stripe::InvalidRequestError)
      expect(retrieves).to eq(2)
      expect(inbox.reload.status).to eq('failed')
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

  describe 'an invoice for a subscription the account does not hold' do
    # The repeated-Checkout defence cancels the duplicate, and Stripe then
    # delivers that duplicate's invoices for the same customer. Applying one
    # would repoint the row at a cancelled subscription and take paid access
    # away from an account that is paying.
    it 'is ignored: the row keeps its own subscription, its state and its dunning clock' do
      row = create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                          stripe_status: 'trialing', stripe_customer_id: customer_b,
                                          stripe_subscription_id: subscription_a, quantity: 3)

      stub_subscription(subscription_a, 'subscription-trialing')
      stub_subscription(subscription_b, 'subscription-past_due')

      expect(fixture_json('event-invoice.payment_failed')['data']['object']['customer']).to eq(customer_b)

      post_stripe_event('event-invoice.payment_failed')
      drain_stripe_jobs

      row.reload

      expect(row.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('trialing')
      expect(row.past_due_since).to be_nil
      expect(Plans.key_for(account)).to eq(Plans::PAID)
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::FOREIGN_SUBSCRIPTION)
    end

    # The legitimate other half: the first invoice of a NEW subscription can
    # arrive before the subscription event that announces it, and a row with
    # no paid access to lose adopts it.
    it 'is adopted when the row holds nothing live' do
      row = cancelled_row(customer: customer_b)

      stub_subscription(subscription_b, 'subscription-past_due')

      post_stripe_event('event-invoice.payment_failed')
      drain_stripe_jobs

      expect(row.reload.stripe_subscription_id).to eq(subscription_b)
      expect(row.access_state).to eq('past_due')
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

    # F8: the event type used to decide the dunning clock, so a replayed
    # `invoice.paid` from before the failure stopped a clock that is still
    # running. The state Stripe reports NOW decides it.
    it 'keeps the dunning clock running when a stale paid invoice lands after the failure' do
      stub_subscription(subscription_b, 'subscription-past_due')

      post_stripe_event('event-invoice.payment_failed')
      drain_stripe_jobs

      clock = row.reload.past_due_since

      expect(clock).to be_present

      # Stripe still says past_due; the older `invoice.paid` is only a trigger.
      post_stripe_event('event-invoice.paid-recovered')
      drain_stripe_jobs

      row.reload

      expect(row.access_state).to eq('past_due')
      expect(row.past_due_since).to eq(clock)
    end

    # `unpaid` is where Stripe gives up. The capture is the real past_due
    # subscription with only `status` changed — producing a genuine unpaid one
    # needs a dunning setting the account does not use.
    it 'takes paid features away once Stripe gives up on the payment' do
      create(:account_config, account:, key: AccountConfig::REMOVE_BRANDING_KEY, value: true)

      stub_subscription(subscription_b, 'subscription-past_due', { 'status' => 'unpaid' })

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

    # The price comes back as a bare id string unless the caller expanded it;
    # reading it as an object left the row with no price at all.
    it 'reads a price that arrived as a bare id instead of an object' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'none', quantity: 1)
      subscription = fixture_json('subscription-active')
      subscription['items']['data'][0]['price'] = fixture_price

      described_class.apply!(row, subscription)

      expect(row.stripe_price_id).to eq(fixture_price)
      expect(row.quantity).to eq(3)
    end

    # A subscription with nothing on our price says nothing about how many
    # seats this account bought: a stranger's quantity is not a seat count and
    # a stranger's price is not ours to record.
    it 'keeps the seats and ids it already had when no item sits on our price' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active', quantity: 4,
                                          stripe_item_id: 'si_ours', stripe_price_id: fixture_price,
                                          stripe_product_id: 'prod_ours')
      subscription = fixture_json('subscription-active')
      subscription['items']['data'][0]['price']['id'] = 'price_somebody_else'
      subscription['items']['data'][0]['quantity'] = 11

      allow(ErrorReport).to receive(:warning)

      described_class.apply!(row, subscription)

      expect(row.quantity).to eq(4)
      expect(row.stripe_item_id).to eq('si_ours')
      expect(row.stripe_price_id).to eq(fixture_price)
      expect(row.stripe_product_id).to eq('prod_ours')
      expect(ErrorReport).to have_received(:warning)
        .with('stripe subscription has no item on our price', hash_including(account_id: account.id))
    end

    it 'records when Stripe says the subscription actually ended, not when its period runs out' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active')

      described_class.apply!(row, fixture_json('subscription-canceled'))

      expect(row.ended_at).to eq(Time.zone.at(1_788_411_093))
      expect(row.current_period_end).to eq(Time.zone.at(1_791_003_076))
    end

    # H10: with no price configured, nothing is on "our price" — a blank
    # never matches an item that has no price.
    it 'matches nothing to a blank price id' do
      ENV['STRIPE_PRICE_ID'] = ''
      subscription = fixture_json('subscription-active')
      subscription['items']['data'][0]['price'] = ''

      expect(described_class.price_item(subscription)).to be_nil
      expect(StripeBilling::SubscriptionPolicy.on_our_price?(subscription)).to be(false)
      expect(StripeBilling::SubscriptionPolicy.ours?(subscription.merge('metadata' => {}), account.id)).to be(false)
    end

    it 'covers every access state the app knows' do
      expect(described_class::STATE_BY_STRIPE_STATUS.values.uniq + ['canceling'])
        .to match_array(Plans::ACCESS_STATES)
    end

    # Which subscription an account holds is the Linker's decision alone;
    # applying an object for ANOTHER subscription writes that object's facts
    # but never moves the id.
    it 'never repoints a row at the subscription object it is handed' do
      row = create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                          stripe_subscription_id: subscription_a, stripe_customer_id: customer_a)

      described_class.apply!(row, fixture_json('subscription-past_due'))

      expect(fixture_json('subscription-past_due')['id']).to eq(subscription_b)
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(row.stripe_customer_id).to eq(customer_a)
    end
  end

  describe ProcessStripeEventJob do
    it 'records the failure, re-raises so Sidekiq retries, and succeeds on a later run' do
      row = cancelled_row

      stub_request(:get, subscription_url(subscription_a))
        .with(query: hash_including('expand' => ['items.data.price']))
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
    # The nightly sweep also asks Stripe which subscriptions each customer
    # has; unless an example is about that, the answer is "just the one".
    before do
      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions\?})
        .to_return(status: 200, body: { object: 'list', data: [] }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

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

    # `status` is nullable and NULL is not 'manual': `where.not` quietly
    # dropped every row that had never been stamped, forever.
    it 'reconciles a row whose status was never set' do
      row = create(:account_subscription, account:, access_state: 'active', status: nil,
                                          stripe_customer_id: customer_a, stripe_subscription_id: subscription_a,
                                          quantity: 3)

      stub_subscription(subscription_a, 'subscription-canceled')
      allow(OperatorAlert).to receive(:deliver).and_return(true)

      described_class.new.perform

      expect(row.reload.access_state).to eq('cancelled')
      expect(row.status).to eq('canceled')
    end

    # One field out of step is still drift: a row missing the one-trial stamp
    # would otherwise be handed a second free trial.
    it 'repairs a single missing field — the one-trial stamp' do
      row = create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                          stripe_customer_id: customer_a, stripe_subscription_id: subscription_a)
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-trialing'))
      row.update_columns(trial_used_at: nil)

      stub_subscription(subscription_a, 'subscription-trialing')
      allow(OperatorAlert).to receive(:deliver).and_return(true)

      report = described_class.new.perform

      expect(row.reload.trial_used_at).to be_present
      expect(report.repaired.sole).to include(account_id: account.id, was: 'trialing', now: 'trialing')
    end

    # The dunning clock is repaired here too, because it is derived in the one
    # shared apply path rather than by whichever event happened to arrive.
    it 'stops a dunning clock that Stripe says has recovered' do
      row = create(:account_subscription, account:, access_state: 'past_due', status: 'past_due',
                                          stripe_status: 'past_due', past_due_since: 3.days.ago,
                                          stripe_customer_id: customer_b, stripe_subscription_id: subscription_b,
                                          quantity: 2)

      stub_subscription(subscription_b, 'subscription-active-recovered')
      allow(OperatorAlert).to receive(:deliver).and_return(true)

      described_class.new.perform

      row.reload

      expect(row.access_state).to eq('active')
      expect(row.past_due_since).to be_nil
    end

    # Stripe is the only place that knows a customer has two live
    # subscriptions: the row can only ever name one of them.
    it 'cancels a second live subscription the row never heard about' do
      row = create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                          stripe_status: 'trialing', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-trialing'))

      stub_subscription(subscription_a, 'subscription-trialing')
      stub_subscription_list(customer_a, { subscription_a => 'active', subscription_b => 'active' })
      stub_duplicate(subscription_b, 'subscription-active')

      cancel_call = stub_cancel(subscription_b)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(cancel_call).to have_been_requested
      expect(report.duplicates.sole).to include(account_id: account.id, cancelled: subscription_b)
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('trialing')
      expect(alerts.size).to eq(1)
      expect(alerts.sole[:body]).to include("cancelled #{subscription_b}")
    end

    # G12: the sweep may cancel, never adopt. A row whose repair failed is
    # stale, and a list showing two live subscriptions is no reason to
    # repoint it at one of them — nor to report a cancellation that never
    # happened.
    it 'neither adopts nor reports a duplicate for a row whose repair failed' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                          stripe_status: 'canceled', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)

      stub_request(:get, subscription_url(subscription_a))
        .with(query: hash_including('expand' => ['items.data.price']))
        .to_return(status: 500, body: '{"error":{"message":"Stripe is having a bad day"}}',
                   headers: { 'Content-Type' => 'application/json' })
      stub_subscription_list(customer_a, { subscription_a => 'active', subscription_b => 'active' })

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:error)
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('cancelled')
      expect(report.duplicates).to be_empty
      expect(report.errors.size).to eq(1)
      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
    end

    # G12, the other half: the sweep may only ever CANCEL. When the row's own
    # subscription turns out to be over by the time the Linker looks (the list
    # was a moment stale), the Linker says so and the sweep neither repoints
    # the row at the other one nor reports a cancellation.
    it 'repoints nothing and reports nothing when the row\'s subscription dies mid-sweep' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-active'))

      # Alive for the repair, gone when the duplicate pass asks again.
      stub_request(:get, subscription_url(subscription_a))
        .with(query: hash_including('expand' => ['items.data.price']))
        .to_return({ status: 200, body: fixture_body('subscription-active'),
                     headers: { 'Content-Type' => 'application/json' } },
                   { status: 200, body: fixture_body('subscription-canceled'),
                     headers: { 'Content-Type' => 'application/json' } })
      stub_subscription_list(customer_a, { subscription_a => 'active', subscription_b => 'active' })
      stub_duplicate(subscription_b, 'subscription-active')
      stub_subscription(subscription_b, 'subscription-active')

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(report.duplicates).to be_empty
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
    end

    # G3: a live subscription on the customer that is not ours is somebody's
    # real purchase. It is left alone and named, never cancelled.
    it 'leaves a subscription for another product alone and names it' do
      row = create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                          stripe_status: 'trialing', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-trialing'))

      stub_subscription(subscription_a, 'subscription-trialing')
      stub_subscription_list(customer_a, { subscription_a => 'active',
                                           'sub_other_product' => listed_subscription('sub_other_product', 'active',
                                                                                      price: 'price_other') })

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(report.duplicates).to be_empty
      expect(report.foreign.sole).to include(account_id: account.id, subscription: 'sub_other_product')
      expect(ErrorReport).to have_received(:warning)
        .with("foreign subscription sub_other_product on customer #{customer_a} left alone",
              hash_including(account_id: account.id))
      expect(alerts.sole[:body]).to include('sub_other_product on customer')
    end

    # G13: internal and operator accounts never bill. A row that carries
    # Stripe ids on one is a mistake, and the sweep must not act on it.
    it 'never repairs or cancels for an internal account' do
      internal = create(:account, :internal)
      row = create(:account_subscription, account: internal, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)

      stub_subscription(subscription_a, 'subscription-canceled')
      stub_subscription_list(customer_a, { subscription_a => 'active', subscription_b => 'active' })
      stub_duplicate(subscription_b, 'subscription-active')
      stub_cancel(subscription_b)

      described_class.new.perform

      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      expect(row.reload.access_state).to eq('active')
    end

    # H7(a): the duplicate pass is skipped for a row whose repair failed on
    # the WRITE, not only on Stripe — a stale row is no basis for cancelling.
    it 'skips the duplicate pass when the repair failed to write, cancelling nothing' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)

      stub_subscription(subscription_a, 'subscription-canceled')
      stub_subscription_list(customer_a, { subscription_a => 'active', subscription_b => 'active' })
      stub_duplicate(subscription_b, 'subscription-active')
      stub_cancel(subscription_b)
      allow(StripeBilling::SubscriptionSync).to receive(:apply!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:error)
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(a_request(:get, %r{api\.stripe\.com/v1/subscriptions\?})).not_to have_been_made
      expect(report.duplicates).to be_empty
      expect(report.errors.size).to eq(1)
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
    end

    # H3: a customer whose subscription list cannot be read to the end is an
    # error for that account, not "no duplicates".
    it 'counts an unreadable subscription list as an error rather than a clean customer' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-active'))

      stub_subscription(subscription_a, 'subscription-active')
      # Every page says there is another.
      stub_subscription_list(customer_a, { subscription_a => 'active' }, has_more: true)
      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:error)
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(a_request(:get, %r{api\.stripe\.com/v1/subscriptions\?}))
        .to have_been_made.times(StripeBilling::Linker::LIST_PAGE_LIMIT)
      expect(report.errors.sole).to include('ListIncomplete')
      expect(report.duplicates).to be_empty
    end

    # G16(a): "repaired" is only ever said of a write that went through.
    it 'counts a row whose write failed as an error, not a repair' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_customer_id: customer_a, stripe_subscription_id: subscription_a,
                                          quantity: 3)

      stub_subscription(subscription_a, 'subscription-canceled')
      allow(StripeBilling::SubscriptionSync).to receive(:apply!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:error)
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(report.repaired).to be_empty
      expect(report.errors.sole).to include("account #{account.id}")
      expect(row.reload.access_state).to eq('active')
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
        .with(query: hash_including('expand' => ['items.data.price']))
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

    # A row Stripe is driving is not the operator's to edit: 'manual' would
    # take it out of the nightly sweep while the card kept being charged, and
    # a local downgrade would be undone by the next webhook.
    it 'refuses to revoke a live Stripe subscription by hand' do
      row = create(:account_subscription, account: parent, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_subscription_id: 'sub_live_one')

      expect { run_rake_task('plans:revoke', parent.id.to_s) }
        .to raise_error(SystemExit).and output(/cancel it at Stripe/).to_stderr

      expect(row.reload.access_state).to eq('active')
    end

    it 'refuses to grant over a live Stripe subscription' do
      row = create(:account_subscription, account: parent, access_state: 'trialing', status: 'trialing',
                                          stripe_status: 'trialing', stripe_subscription_id: 'sub_live_two')

      expect { run_rake_task('plans:grant', parent.id.to_s, '4') }
        .to raise_error(SystemExit).and output(/cancel it at Stripe/).to_stderr

      expect(row.reload.status).to eq('trialing')
    end

    it 'still revokes a plan the operator granted by hand' do
      create(:account_subscription, account: parent, access_state: 'active', status: 'manual', quantity: 2)

      run_rake_task('plans:revoke', parent.id.to_s)

      expect(parent.reload.account_subscription.access_state).to eq('cancelled')
    end

    # G7: a manual row is the operator's whatever it still carries — a stale
    # subscription id and a paid access_state are not a live Stripe
    # subscription. Only the raw Stripe status is.
    it 'revokes a manual plan that still carries an old Stripe id' do
      row = create(:account_subscription, account: parent, access_state: 'active', status: 'manual', quantity: 2,
                                          stripe_subscription_id: 'sub_old', stripe_status: 'active')

      # `abort` is a SystemExit: caught here so a refusal is a failure, not an exit.
      expect { run_rake_task('plans:revoke', parent.id.to_s) }.not_to raise_error

      expect(row.reload.access_state).to eq('cancelled')
    end

    # H2: revoking a manual plan clears the stale Stripe ids with it, so the
    # next grant is not refused for a subscription that was never Stripe's.
    it 'lets a revoked manual plan be granted again despite stale Stripe ids' do
      row = create(:account_subscription, account: parent, access_state: 'active', status: 'manual', quantity: 2,
                                          stripe_subscription_id: 'sub_old', stripe_status: 'active',
                                          stripe_customer_id: 'cus_kept', trial_used_at: 1.month.ago)

      expect { run_rake_task('plans:revoke', parent.id.to_s) }.not_to raise_error
      expect(row.reload).to have_attributes(access_state: 'cancelled', stripe_subscription_id: nil, stripe_status: nil,
                                            stripe_customer_id: 'cus_kept')
      expect(row.trial_used_at).to be_present

      expect { run_rake_task('plans:grant', parent.id.to_s, '3') }.not_to raise_error
      expect(row.reload).to have_attributes(access_state: 'active', status: 'manual', quantity: 3)
    end

    # H7(c): the refusal keys on the raw Stripe status alone — a paid
    # access_state left over on a dead Stripe subscription is not "live".
    it 'grants over a Stripe row whose access is still paid but whose Stripe status is dead' do
      row = create(:account_subscription, account: parent, access_state: 'active', status: 'active',
                                          stripe_status: 'canceled', stripe_subscription_id: 'sub_dead')

      expect { run_rake_task('plans:grant', parent.id.to_s, '2') }.not_to raise_error
      expect(row.reload).to have_attributes(status: 'manual', quantity: 2, stripe_subscription_id: nil)
    end

    it 'grants over a dead Stripe subscription, clearing its ids and keeping the customer and the trial stamp' do
      stamp = 3.months.ago.change(usec: 0)
      row = create(:account_subscription, account: parent, access_state: 'active', status: 'canceled',
                                          stripe_status: 'canceled', stripe_customer_id: 'cus_kept',
                                          stripe_subscription_id: 'sub_dead', trial_used_at: stamp)

      run_rake_task('plans:grant', parent.id.to_s, '3')

      row.reload

      expect(row).to have_attributes(access_state: 'active', status: 'manual', quantity: 3,
                                     stripe_subscription_id: nil, stripe_status: nil,
                                     stripe_customer_id: 'cus_kept', trial_used_at: stamp)
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

      expect { described_class.check! }.to raise_error(/STRIPE_SECRET_KEY must be a live key.*in production/)
    end

    # A key that is neither sk_live_ nor sk_test_ has no mode at all, and
    # "not obviously a test key" was enough to boot production on it.
    it 'refuses to boot production on a key that is neither live nor test' do
      ENV['STRIPE_SECRET_KEY'] = 'sk_invalid'
      Rails.env = 'production'

      expect { described_class.check! }.to raise_error(/STRIPE_SECRET_KEY must be a live key.*in production/)
    end

    # G8: the browser and the server must be on the same Stripe account; a
    # live secret with a test publishable key is two accounts.
    it 'refuses a publishable key whose mode does not match production, naming both keys' do
      ENV['STRIPE_SECRET_KEY'] = 'sk_live_realkey'
      ENV['STRIPE_PUBLISHABLE_KEY'] = 'pk_test_leftover'
      Rails.env = 'production'

      expect { described_class.check! }
        .to raise_error(/STRIPE_PUBLISHABLE_KEY must be a live key \(pk_live_…\) in production/)

      ENV['STRIPE_PUBLISHABLE_KEY'] = 'pk_live_realkey'

      expect { described_class.check! }.not_to raise_error

      ENV['STRIPE_SECRET_KEY'] = 'sk_test_fake'
      ENV['STRIPE_PUBLISHABLE_KEY'] = 'pk_test_fake'

      expect { described_class.check! }
        .to raise_error(/STRIPE_SECRET_KEY must be a live key.*STRIPE_PUBLISHABLE_KEY must be a live key/)
    end

    it 'names the same problem outside production, where only a test key belongs' do
      ENV['STRIPE_SECRET_KEY'] = 'sk_invalid'

      allow(Rails.logger).to receive(:warn)

      Rails.env = 'development'

      expect { described_class.check! }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/STRIPE_SECRET_KEY must be a test key.*outside production/)
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

  # G1: a row lock is held across the Stripe calls, so every one of them is
  # on a short leash and the lock itself gives up rather than queueing
  # workers behind an outage.
  describe 'how long the app will wait' do
    it 'builds every Stripe client with short timeouts and a single retry' do
      Stripe.open_timeout = 30
      Stripe.read_timeout = 80
      Stripe.max_network_retries = 2

      expect(StripeBilling.transport_of(StripeBilling.client))
        .to eq(open_timeout: 5, read_timeout: 15, max_network_retries: 1)
    end

    it 'limits how long a worker waits for another worker on the same account' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')

      statements = []
      callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        StripeBilling::Linker.link_and_apply!(row, subscription_a)
      end

      expect(statements).to include("SET LOCAL lock_timeout = '10s'")
      expect(statements.index { |sql| sql.include?('lock_timeout') })
        .to be < statements.index { |sql| sql.include?('FOR UPDATE') }
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

# The claim the whole inbox design rests on is that delivery ORDER stops
# mattering, because the event is only a trigger and the object Stripe
# returns now is the truth. That only holds if the fetch and the write are one
# step: fetching first and locking second lets two workers each hold a
# snapshot and race for the write, and the OLDER snapshot can land last.
#
# A second top-level group because it runs without the wrapping test
# transaction — a real row lock between two real connections is the thing
# being proved (see the creation-lock group in quota_spec).
RSpec.describe 'Two Stripe workers on one account', type: :request do
  self.use_transactional_tests = false

  let(:subscription_a) { 'sub_1UBSbL4rEeOqtLcXAD6ynIIK' }
  let(:customer_a) { 'cus_VBqHCUoJle1zGV' }

  stash_env(*StripeBilling::CONFIG_KEYS.keys, 'BILLING_ENABLED')

  before do
    ENV['STRIPE_SECRET_KEY'] = 'sk_test_fake'
    ENV['STRIPE_PUBLISHABLE_KEY'] = 'pk_test_fake'
    ENV['STRIPE_WEBHOOK_SECRET'] = 'whsec_testsecret'
    ENV['STRIPE_PRICE_ID'] = 'price_1UAt8N4rEeOqtLcX1amJxYdZ'
    ENV['STRIPE_PORTAL_CONFIGURATION_ID'] = 'bpc_test'
    ENV['BILLING_ENABLED'] = 'true'
  end

  def fixture_body(name)
    Rails.root.join("spec/fixtures/stripe/#{name}.json").read
  end

  def inbox_row(event_id, created_at)
    StripeEventInbox.create!(stripe_event_id: event_id, event_type: 'customer.subscription.updated',
                             payload: { id: event_id, data: { object: { id: subscription_a } } }.to_json,
                             status: 'pending', stripe_created_at: created_at)
  end

  it 'leaves the row on the state Stripe reported LAST, not on the snapshot fetched first' do
    account = create(:account)
    # The row starts on neither of the two states the workers will fetch, so
    # whichever write lands last is the state that shows.
    row = create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                        stripe_status: 'trialing', stripe_customer_id: customer_a,
                                        stripe_subscription_id: subscription_a, quantity: 3)
    first = inbox_row('evt_race_first', 2.minutes.ago)
    second = inbox_row('evt_race_second', 1.minute.ago)

    fetches = 0
    counter = Mutex.new
    second_worker_finished = Queue.new
    second_worker_may_start = Queue.new

    # The first fetch answers `active` (the older truth) but only after giving
    # the other worker every chance to do its whole job first. The second
    # fetch answers `canceled` — what Stripe says now.
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{subscription_a}})
      .with(query: hash_including('expand' => ['items.data.price']))
      .to_return do
        mine = counter.synchronize { fetches += 1 }

        if mine == 1
          second_worker_may_start << true
          second_worker_finished.pop(timeout: 5)
        end

        { status: 200, body: fixture_body(mine == 1 ? 'subscription-active' : 'subscription-canceled'),
          headers: { 'Content-Type' => 'application/json' } }
      end

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_worker_may_start.pop(timeout: 5)

        ProcessStripeEventJob.new.perform(second.id)
        second_worker_finished << true

        :finished
      end
    end

    ProcessStripeEventJob.new.perform(first.id)

    # `value` re-raises whatever the worker raised: a worker that crashed
    # would otherwise look exactly like one that lost the race on purpose.
    expect(worker.value).to eq(:finished)
    expect(fetches).to eq(2)
    expect(row.reload.access_state).to eq('cancelled')
    expect(row.stripe_status).to eq('canceled')
  ensure
    StripeEventInbox.where(stripe_event_id: %w[evt_race_first evt_race_second]).delete_all
    account&.destroy!
  end
end
