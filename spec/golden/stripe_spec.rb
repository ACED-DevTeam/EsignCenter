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

# The fixture actors, the credentials every example runs against and the
# Stripe stubs both this file and spec/golden/seats_spec.rb drive live in
# spec/support/stripe_test_account.rb — a shared context, loaded for every
# spec file, so a fixture id or a key can never drift between the two.

RSpec.describe 'Stripe billing', type: :request do # rubocop:disable RSpec/MultipleDescribes
  include_context 'with a Stripe test account'

  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:api_headers) { { 'x-auth-token': user.access_token.token } }
  # The customer the `stripe trigger invoice.payment_failed` fixture made: no
  # account here owns it, which is exactly what makes it the unknown case.
  let(:customer_unknown) { 'cus_VBqJXVDDFKe0Zk' }

  # One MCP token per user for the whole example (see mcp_token_for).
  let(:mcp_tokens) { {} }

  before do
    # Every duplicate the app cancels is asked what it ever collected. Unless
    # an example says otherwise the answer is "nothing" — a later stub in the
    # example itself wins over this one.
    stub_invoice_list(nil, [])
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

  # The marker's AUTHORITY: a metadata write, which only our secret key can
  # make, stamped immediately BEFORE the cancel and keyed idempotently on the
  # subscription. Matching on the exact value means an example expecting the
  # automatic marker fails outright if the code chooses the manual one — and
  # a cancel that skipped this write hits no stub at all.
  def stub_mark_duplicate(id, marker: StripeBilling::DUPLICATE_CANCEL_MARKER)
    value = StripeBilling::Linker::DUPLICATE_CANCEL_METADATA_FOR.fetch(marker)

    stub_request(:post, subscription_url(id))
      .with(body: hash_including('metadata' => hash_including(
        StripeBilling::DUPLICATE_CANCEL_METADATA_KEY => value
      )),
            headers: { 'Idempotency-Key' => "mark-duplicate-#{id}" })
      .to_return(status: 200, body: { id:, object: 'subscription' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  # The durable "a person still owes this refund" stamp the app leaves on a
  # dead duplicate it could not return on its own. Metadata again — only our
  # secret key can write it — and keyed idempotently on the subscription, so
  # a later pass over the same debt writes nothing new.
  def stub_manual_refund_owed(id)
    stub_request(:post, subscription_url(id))
      .with(body: hash_including('metadata' => hash_including(
        StripeBilling::MANUAL_REFUND_OWED_METADATA_KEY => StripeBilling::MANUAL_REFUND_OWED_METADATA
      )),
            headers: { 'Idempotency-Key' => "manual-refund-owed-#{id}" })
      .to_return(status: 200, body: { id:, object: 'subscription' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  # And cancelled with the same expansion, so the answer says what it charged
  # — stamped with the marker its age earns, so a later look can tell both
  # that we did it and whether its money is ours to send back automatically.
  # The metadata write that carries that marker is stubbed with it: both
  # requests are on the wire, or the example fails.
  def stub_cancel(id, fixture = 'subscription-canceled', overrides = {}, invoice: unpaid_invoice(id),
                  marker: StripeBilling::DUPLICATE_CANCEL_MARKER)
    stub_mark_duplicate(id, marker:)

    stub_request(:delete, subscription_url(id))
      .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND,
                                  'cancellation_details' => { 'comment' => marker }))
      .to_return(status: 200, body: fixture_json(fixture).merge(overrides.stringify_keys)
                                                          .merge('id' => id, 'latest_invoice' => invoice).to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  # What a subscription WE cancelled looks like afterwards. The metadata is
  # the marker; the `cancellation_details.comment` beside it is the copy a
  # person reads in the dashboard and is never authority — pass `comment:`
  # alone (with `metadata: false`) to build the customer-typed forgery.
  def marked_by_us(marker = StripeBilling::DUPLICATE_CANCEL_MARKER, fixture: 'subscription-canceled',
                   comment: marker, metadata: true, extra_details: {})
    stamped = fixture_json(fixture)['metadata'].to_h
    if metadata
      stamped = stamped.merge(
        StripeBilling::DUPLICATE_CANCEL_METADATA_KEY =>
          StripeBilling::Linker::DUPLICATE_CANCEL_METADATA_FOR.fetch(marker),
        StripeBilling::DUPLICATE_CANCEL_METADATA_AT_KEY => '1788411000'
      )
    end

    { 'metadata' => stamped,
      'cancellation_details' => { 'comment' => comment }.merge(extra_details.stringify_keys) }
  end

  # A trial's first invoice: $0, no payment behind it.
  def unpaid_invoice(subscription_id)
    { id: "in_trial_#{subscription_id}", object: 'invoice', amount_paid: 0, currency: 'usd',
      payments: { object: 'list', data: [] } }
  end

  # An invoice that collected money — the shape this API version uses
  # (`payments`, not a top-level `payment_intent`). One PaymentIntent settled
  # it by default; `payments:` names several, which Stripe allows. Two
  # invoices may name the SAME intent, which is how one card charge settles
  # both — and why a refund is made per intent, not per invoice. `id:`
  # distinguishes the invoices of a duplicate that ran for more than one
  # cycle, and `created:` is what makes one of them the latest.
  def paid_invoice(subscription_id, amount:, payment_intent: "pi_#{subscription_id}", payments: [payment_intent],
                   id: "in_paid_#{subscription_id}", created: 1_788_411_000)
    { id:, object: 'invoice', amount_paid: amount, currency: 'usd', created:,
      payments: { object: 'list', data: payments.map { |payment| invoice_payment(payment) } } }
  end

  # One entry of that `payments` list. A bare intent id is the ordinary
  # invoice settled by a single payment. A Hash names the intent AND what
  # that payment itself paid — the InvoicePayment's own `amount_paid`, which
  # is what Stripe states when several payments settle one invoice and the
  # only honest way to split the invoice between them. `amount: nil` is the
  # payment that states nothing.
  def invoice_payment(payment)
    intent, amount = payment.is_a?(Hash) ? payment.values_at(:intent, :amount) : [payment, nil]
    entry = { object: 'invoice_payment', status: 'paid',
              payment: { type: 'payment_intent', payment_intent: intent } }

    amount.nil? ? entry : entry.merge(amount_paid: amount)
  end

  # What Stripe answers when the app asks what a subscription ever collected.
  # `subscription_id` nil matches any — the default "nothing was charged".
  def stub_invoice_list(subscription_id, invoices, has_more: false)
    query = { 'status' => 'paid' }
    query['subscription'] = subscription_id if subscription_id

    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/invoices})
      .with(query: hash_including(query))
      .to_return(status: 200, body: { object: 'list', data: invoices, has_more: }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  # What a payment took and how much of it has already gone back, read off
  # the charge behind the PaymentIntent. `refunded:` is the whole point: a
  # charge already returned (by hand, or by an attempt whose idempotency key
  # has expired) must not be refunded a second time.
  def payment_intent_body(payment_intent, amount:, refunded: 0)
    { id: payment_intent, object: 'payment_intent',
      latest_charge: { id: "ch_#{payment_intent}", object: 'charge', amount:, amount_captured: amount,
                       amount_refunded: refunded, currency: 'usd' } }.to_json
  end

  def stub_payment_intent(payment_intent, amount:, refunded: 0)
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/payment_intents/#{Regexp.escape(payment_intent)}})
      .to_return(status: 200, body: payment_intent_body(payment_intent, amount:, refunded:),
                 headers: { 'Content-Type' => 'application/json' })
  end

  # A refund the app can make, and the charge truth behind it: by default the
  # payment took exactly what is being refunded and nothing has come back yet
  # (`charge_amount:`/`refunded:` say otherwise).
  def stub_refund(payment_intent, amount:, charge_amount: amount, refunded: 0)
    stub_payment_intent(payment_intent, amount: charge_amount, refunded:)

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

  # --- what the account can DO afterwards ----------------------------------
  #
  # Scope item 4 asks this matrix for "DB + permission assertions": every row
  # ends by asking what the account is actually allowed to do, not only what
  # its columns say. The two answers are the whole product — paid access, or
  # the free plan — so they are written once here and asked at the tail of
  # every matrix example (and as `it_behaves_like` where the example group
  # sets its state up in a `before`).

  # One MCP token per user for the whole example, with the account's MCP
  # switch on: the same token is re-presented after a state change, which is
  # what makes "the token is refused at request time" a real assertion.
  def mcp_token_for(for_account, as_user)
    for_account.account_configs.find_or_create_by!(key: AccountConfig::ENABLE_MCP_KEY) { |c| c.value = true }

    mcp_tokens[as_user.id] ||= as_user.mcp_tokens.create!(name: 'Golden')
  end

  def post_mcp_tools_list(for_account, as_user)
    post '/mcp',
         headers: { 'Authorization' => "Bearer #{mcp_token_for(for_account, as_user).token}",
                    'Content-Type' => 'application/json' },
         params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json
  end

  # Branding removal only shows when the account asked for it, so the config
  # is put in place before it is asked about: what is being proved is that
  # the PLAN decides whether it takes effect, not whether the row exists.
  def branding_asked_for!(for_account)
    for_account.account_configs.find_or_create_by!(key: AccountConfig::REMOVE_BRANDING_KEY) { |c| c.value = true }
  end

  def expect_paid_access(for_account = account, as_user: user)
    branding_asked_for!(for_account.reload)

    expect(Plans.key_for(for_account)).to eq(Plans::PAID)
    expect(Entitlements.allowed?(for_account, :api)).to be(true)
    expect(Accounts.branding_removed?(for_account)).to be(true)

    get '/api/templates', headers: { 'x-auth-token': as_user.access_token.token }

    expect(response).to have_http_status(:ok)

    post_mcp_tools_list(for_account, as_user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('result', 'tools')).to be_present
  end

  # `token_status` is 403 (the plan does not include the API) everywhere
  # except on an account Session 7 also SUSPENDED: a suspended account's
  # tokens are refused by the state guard first, which answers 401 and never
  # says why (lib/account_states.rb).
  def expect_free_plan(for_account = account, as_user: user, token_status: :forbidden)
    branding_asked_for!(for_account.reload)

    expect(Plans.key_for(for_account)).to eq(Plans::FREE)
    expect(Entitlements.allowed?(for_account, :api)).to be(false)
    expect(Accounts.branding_removed?(for_account)).to be(false)

    get '/api/templates', headers: { 'x-auth-token': as_user.access_token.token }

    expect(response).to have_http_status(token_status)

    post_mcp_tools_list(for_account, as_user)

    expect(response).to have_http_status(token_status)
  end

  shared_examples 'an account with paid access' do
    it 'keeps the paid plan, the API, MCP and its unbranded pages' do
      expect_paid_access
    end
  end

  shared_examples 'an account on the free plan' do
    it 'is on the free plan, with the API and MCP refused and branding back' do
      expect_free_plan
    end
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

    # A repeated delivery must never make a second row. It IS, though, the
    # cheapest chance to put back a job that was lost after its row
    # committed (the enqueue raised, the worker died) — otherwise the event
    # waits for the 06:00 sweep. Only a row genuinely WAITING for a worker is
    # put back: see the three examples below it.
    it 'acknowledges a repeated delivery without a second row, and re-enqueues one still pending' do
      2.times { post_stripe_event('event-customer.subscription.created-trialing') }

      expect(response).to have_http_status(:ok)
      expect(StripeEventInbox.count).to eq(1)
      expect(ProcessStripeEventJob.jobs.size).to eq(2)
      expect(ProcessStripeEventJob.jobs.map { |job| job['args'].first }.uniq)
        .to eq([StripeEventInbox.sole.id])
    end

    it 'enqueues nothing for a repeated delivery of an event it has already decided' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')

      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(StripeEventInbox.sole.status).to eq('processed')

      post_stripe_event('event-customer.subscription.created-trialing')

      expect(response).to have_http_status(:ok)
      expect(StripeEventInbox.count).to eq(1)
      expect(ProcessStripeEventJob.jobs).to be_empty
    end

    # L4(b): a `processing` row belongs to a worker right now. A second job
    # would bump `attempts` again and could push a genuinely retryable row
    # out of its retry budget; deciding that worker died is the stuck-row
    # sweep's job, not the door's.
    it 'enqueues nothing for a repeated delivery of a row a worker is already holding' do
      post_stripe_event('event-customer.subscription.created-trialing')
      StripeEventInbox.sole.update!(status: StripeEventInbox::PROCESSING)
      ProcessStripeEventJob.jobs.clear

      post_stripe_event('event-customer.subscription.created-trialing')

      expect(response).to have_http_status(:ok)
      expect(StripeEventInbox.count).to eq(1)
      expect(ProcessStripeEventJob.jobs).to be_empty
    end

    # L4(a): a row that has burned its retry budget was deliberately given up
    # on, and a dashboard "Resend" must not quietly restart it behind the
    # operator's back — `StripeEventInbox.retryable` and the nightly sweep
    # both stop at MAX_ATTEMPTS, and this door has to agree with them.
    it 'enqueues nothing for a repeated delivery of a failed row that has spent its retries' do
      post_stripe_event('event-customer.subscription.created-trialing')
      StripeEventInbox.sole.update!(status: StripeEventInbox::FAILED,
                                    attempts: StripeEventInbox::MAX_ATTEMPTS)
      ProcessStripeEventJob.jobs.clear

      post_stripe_event('event-customer.subscription.created-trialing')

      expect(response).to have_http_status(:ok)
      expect(ProcessStripeEventJob.jobs).to be_empty
    end

    it 're-enqueues a failed row that still has retries left' do
      post_stripe_event('event-customer.subscription.created-trialing')
      StripeEventInbox.sole.update!(status: StripeEventInbox::FAILED,
                                    attempts: StripeEventInbox::MAX_ATTEMPTS - 1)
      ProcessStripeEventJob.jobs.clear

      post_stripe_event('event-customer.subscription.created-trialing')

      expect(ProcessStripeEventJob.jobs.size).to eq(1)
      expect(ProcessStripeEventJob.jobs.sole['args'].first).to eq(StripeEventInbox.sole.id)
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

    # A4 (review 7): the moment the trial ends and the card is charged for the
    # first time — the one transition in the state table that starts taking
    # money — driven through the real door. Everything the trial wrote stays
    # (the row keeps its trial stamp, so this account can never be sold a
    # second trial); the period moves to the one being billed.
    it 'turns the trial into an active subscription when Stripe says the first invoice was paid' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(row.reload.access_state).to eq('trialing')

      trial_stamp = row.trial_used_at

      stub_subscription(subscription_a, 'subscription-active')
      post_stripe_event('event-customer.subscription.updated-active')
      drain_stripe_jobs

      row.reload

      expect(row.access_state).to eq('active')
      expect(row.status).to eq('active')
      expect(row.stripe_status).to eq('active')
      expect(row.cancel_at_period_end).to be(false)
      # The trial is spent, and stays spent.
      expect(row.trial_used_at).to eq(trial_stamp)
      # The period being billed, not the trial's.
      expect(row.current_period_start).to eq(Time.zone.at(1_788_411_076))
      expect(row.current_period_end).to eq(Time.zone.at(1_791_003_076))
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed', last_error: nil)

      expect_paid_access
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

    # Both Stripe calls Accounts::Deletion.cancel_subscription! makes, asserted
    # separately: the metadata write carries the AUTHORITY (only a secret key
    # can make it) and the cancel carries the human-readable comment beside it.
    # A cancel that skipped the marker would hit no stub at all.
    def stub_account_deletion_cancel(id)
      mark = stub_request(:post, subscription_url(id))
             .with(body: hash_including('metadata' => hash_including(
               StripeBilling::DUPLICATE_CANCEL_METADATA_KEY => StripeBilling::ACCOUNT_DELETION_METADATA
             )))
             .to_return(status: 200, body: { id:, object: 'subscription' }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

      # A Stripe cancel is a DELETE, and the gem puts its parameters in the
      # QUERY STRING rather than a body — matching on a body here would match
      # nothing and quietly prove nothing.
      cancel = stub_request(:delete, subscription_url(id))
               .with(query: hash_including('cancellation_details' =>
                                             { 'comment' => StripeBilling::ACCOUNT_DELETION_MARKER }))
               .to_return(status: 200,
                          body: fixture_json('subscription-canceled').merge('id' => id).to_json,
                          headers: { 'Content-Type' => 'application/json' })

      [mark, cancel]
    end

    # An account whose last member joined another team, and a Checkout they
    # had already started finishing afterwards (review 7, D50 D3).
    #
    # Checkout is created against the account that clicked and leaves no local
    # record of itself, so the move cannot see one in flight: the person
    # accepts the invitation, their old account is archived behind them, and
    # then the Stripe tab they left open days ago completes. The session still
    # names the old account in its `client_reference_id`, so the webhook
    # resolves it perfectly — and used to hand it a live subscription. That
    # account has NOBODY in it: no one can sign in to it, reach its billing
    # page, open its Customer Portal or cancel anything, so the card would have
    # gone on being charged every month with no door left anywhere to stop it.
    #
    # The barrier that already refuses paid access to an account being purged
    # is extended to cover this, and it is told apart from every other archived
    # account by the AccountMove row the move writes. Refusing the access is
    # not enough on its own, though — the money is the part that hurts — so the
    # subscription is also cancelled at Stripe through the app's existing
    # cancel path, and a person is told, because whether anything goes back on
    # the card is not a decision this code may make by itself.
    it 'refuses a Checkout completed for an account its last member has left, and stops the card' do
      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }

      gone = create(:account)
      mover = create(:user, account: gone)

      # The real move, through the real code: what makes this account
      # different from any other archived one is the row that move writes.
      Accounts::MoveUser.call(user: mover, to: account)

      expect(gone.reload.archived_at).to be_present
      expect(gone.users.active).to be_empty

      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      mark, cancel = stub_account_deletion_cancel(subscription_c)

      post_stripe_event(nil, body: checkout_body(gone.id))
      drain_stripe_jobs

      row = AccountSubscription.find_by!(account_id: gone.id)

      # Stripe's facts are still written down, so the money history stays
      # readable — but no paid access is granted on them.
      expect(row.stripe_subscription_id).to eq(subscription_c)
      expect(row.stripe_customer_id).to eq(customer_c)
      expect(row.access_state).to eq('cancelled')
      expect(Plans.key_for(gone.reload)).to eq(Plans::FREE)

      # And the card stops being charged, under the marker only our secret key
      # can write.
      expect(mark).to have_been_requested
      expect(cancel).to have_been_requested
      expect(row.reload.stripe_status).to eq('canceled')

      alert = alerts.sole

      expect(alert[:subject]).to include('moved away')
      expect(alert[:body]).to include(subscription_c)
      expect(alert[:body]).to include(gone.id.to_s)
      expect(StripeEventInbox.sole).to have_attributes(status: 'processed', account_id: gone.id)
    end

    # A5b (review 7). The example above lands on `cancelled` twice over: the
    # barrier refuses the access, and the cancel that follows writes Stripe's
    # own `canceled` back onto the row. This one takes the second half away —
    # Stripe will not accept the cancellation (an outage) — because the
    # barrier is only worth having for exactly this case: an account with
    # nobody in it, a subscription Stripe still calls trialing, and no paid
    # access all the same. The event is still recorded rather than failed and
    # retried: the cancel is best effort, the alert has already gone out, and
    # a webhook whose job is to write down what Stripe said must write it down.
    it 'keeps paid access off a moved-away account even when Stripe will not take the cancellation' do
      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)
      allow(ErrorReport).to receive(:error)

      gone = create(:account)

      Accounts::MoveUser.call(user: create(:user, account: gone), to: account)

      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      stub_request(:post, subscription_url(subscription_c))
        .to_return(status: 200, body: { id: subscription_c, object: 'subscription' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
      failed_cancel = stub_request(:delete, subscription_url(subscription_c))
                      .to_return(status: 500, body: '{"error":{"message":"Stripe is having a bad day"}}',
                                 headers: { 'Content-Type' => 'application/json' })

      post_stripe_event(nil, body: checkout_body(gone.id))
      drain_stripe_jobs

      row = AccountSubscription.find_by!(account_id: gone.id)

      expect(failed_cancel).to have_been_requested.at_least_once
      # Nothing cancelled it: Stripe still says trialing, and the row says so
      # too. The access verdict is the barrier's alone.
      expect(row.stripe_status).to eq('trialing')
      expect(row.access_state).to eq('cancelled')
      expect(Plans.key_for(gone.reload)).to eq(Plans::FREE)
      expect(alerts.sole[:subject]).to include('moved away')
      expect(ErrorReport).to have_received(:error).with(anything, hash_including(account_id: gone.id))
      expect(StripeEventInbox.sole).to have_attributes(status: 'processed', account_id: gone.id)
    end

    # The barrier has to name the moved-away case and nothing else.
    # `archived_at` on its own is far too broad to hang a money decision on:
    # the purge stamps it on the tombstone it leaves behind and on every
    # testing child it destroys, and it is what every ordinary "this account is
    # gone" door in the app already reads. Barring those too would refuse paid
    # access to accounts that are simply closed for other reasons — and, worse,
    # would send this path's Stripe cancel after subscriptions it has no
    # business ending.
    it 'tells an account archived by a move apart from every other archived account' do
      gone = create(:account)

      Accounts::MoveUser.call(user: create(:user, account: gone), to: account)

      closed = create(:account, archived_at: Time.current)
      claimed = create(:account, purge_started_at: Time.current)

      expect(StripeBilling::SubscriptionSync.moved_away?(gone.reload)).to be(true)
      expect(StripeBilling::SubscriptionSync.moved_away?(closed)).to be(false)
      expect(StripeBilling::SubscriptionSync.moved_away?(claimed)).to be(false)
      expect(StripeBilling::SubscriptionSync.moved_away?(account)).to be(false)

      # Both barred states still answer the one question the barrier asks, and
      # an ordinary closed account is not one of them.
      expect(StripeBilling::SubscriptionSync.barred?(cancelled_row(for_account: gone))).to be(true)
      expect(StripeBilling::SubscriptionSync.barred?(cancelled_row(for_account: claimed,
                                                                   customer: customer_b))).to be(true)
      expect(StripeBilling::SubscriptionSync.barred?(cancelled_row(for_account: closed,
                                                                   customer: customer_unknown))).to be(false)
    end

    # An account that was standalone when it started Checkout writes its OWN
    # id into client_reference_id. If it has been linked under a parent by
    # the time the webhook is processed, that reference no longer names an
    # account that pays for itself — and resolving it through
    # Plans.billing_account handed the PARENT's row a subscription living on
    # the CHILD's Stripe customer. The Linker would then run the duplicate
    # machinery between the parent's real subscription and the child's and
    # cancel and refund the wrong one. The browser door refuses a child's
    # purchase outright (require_own_billing!); this is the same refusal on
    # the webhook path, and the child's own row gets the non-customer verdict
    # with its unmanaged Stripe ids reported.
    it 'never lands a linked child\'s Checkout on the parent\'s row' do
      parent = create(:account)
      child = Account.create!(name: 'Team', locale: 'en-US', timezone: 'UTC',
                              linked_account_account: AccountLinkedAccount.new(account_type: :linked,
                                                                               account: parent))
      parent_row = create(:account_subscription, account: parent, access_state: 'active', status: 'active',
                                                 stripe_status: 'active', stripe_customer_id: customer_a,
                                                 stripe_subscription_id: subscription_a, quantity: 3)
      # The child bought for itself before it was linked, so it holds its own
      # Stripe customer — and nothing in the app reads this row any more.
      child_row = cancelled_row(for_account: child, customer: customer_c)

      # Everything the wrong path would need, registered so that taking it
      # leaves a mark: a cancel of either subscription is a failed example.
      stub_subscription(subscription_a, 'subscription-active')
      stub_duplicate(subscription_a, 'subscription-active')
      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      stub_duplicate(subscription_c, 'subscription-trialing-checkout')
      stub_cancel(subscription_a)
      stub_cancel(subscription_c)
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: checkout_body(child.id))
      drain_stripe_jobs

      expect(parent_row.reload).to have_attributes(access_state: 'active', stripe_customer_id: customer_a,
                                                   stripe_subscription_id: subscription_a)
      expect(child_row.reload.stripe_subscription_id).to be_nil
      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::NON_CUSTOMER_ACCOUNT)
      expect(ErrorReport).to have_received(:warning)
        .with(/unmanaged Stripe subscription/, hash_including(account_id: child.id))
    end

    # The Checkout RETURN door only applies a session that names EXACTLY the
    # customer the row already holds (known_customer?), because Checkout
    # created that row and that customer before the session ever existed.
    # The webhook path has to ask the same question or it becomes the way
    # around it: a subscription somebody else's Stripe customer is paying for
    # would be linked onto this row, and they would go on paying for it.
    it 'links nothing when the session names a customer the row does not hold' do
      row = cancelled_row(customer: customer_a)

      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      stub_duplicate(subscription_c, 'subscription-trialing-checkout')
      allow(ErrorReport).to receive(:warning)

      expect(fixture_json(checkout_event)['data']['object']['customer']).to eq(customer_c)

      post_stripe_event(nil, body: checkout_body(account.id))
      drain_stripe_jobs

      expect(row.reload).to have_attributes(access_state: 'cancelled', stripe_customer_id: customer_a,
                                            stripe_subscription_id: nil)
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      # Review 6 C3: the two doors now record the SAME verdict for the same
      # rule, in words that say what happened — the label used to be
      # 'checkout session on another customer' here and nothing at all on the
      # browser door.
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::CUSTOMER_MISMATCH,
                            account_id: account.id)
      expect(ProcessStripeEventJob::CUSTOMER_MISMATCH).to eq('customer mismatch')
      expect(ErrorReport).to have_received(:warning)
        .with(/could not be matched to account #{account.id}/, hash_including(account_id: account.id))

      expect_free_plan
    end

    # T1: Checkout is the door duplicates actually come through — two tabs,
    # two completed sessions — so it is the door where a refusal to refund
    # must not lose the debt. The whole handler runs in one lock, and the
    # note the Linker makes inside it is rolled back with everything else
    # when the refusal escapes; it is made again outside, where it survives.
    # The event still fails and retries: the money is owed either way, and
    # now the nightly sweep has something to come back to.
    it 'records the debt when a Checkout duplicate is cancelled and its refund refused' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_c,
                                          stripe_subscription_id: subscription_a, quantity: 1)
      collected = { id: 'in_no_payment', object: 'invoice', amount_paid: 3000, currency: 'usd',
                    created: 1_788_411_000, payments: { object: 'list', data: [] } }

      stub_subscription(subscription_a, 'subscription-active', { 'created' => 1_000 })
      stub_duplicate(subscription_c, 'subscription-trialing-checkout', { 'created' => 2_000 }, invoice: collected)
      cancel_call = stub_cancel(subscription_c, 'subscription-trialing-checkout', invoice: collected)
      stub_invoice_list(subscription_c, [collected])

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: checkout_body(account.id))

      inbox = StripeEventInbox.sole

      expect { ProcessStripeEventJob.new.perform(inbox.id) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable, /names no payment intent to refund/)
      # Cancelled at Stripe, nothing refunded, and the row now knows what is
      # owed on it — the account keeps the subscription it was already paying
      # for.
      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(row.reload).to have_attributes(stripe_subscription_id: subscription_a,
                                            refund_owed_subscription_id: subscription_c)
      expect(inbox.reload.status).to eq('failed')
    end

    # A5a (review 7): the ORDINARY ending of the same story, through the same
    # door. Two tabs, two completed Checkouts; the second one already charged
    # the card (the trial was spent, so Stripe collects during Checkout). The
    # subscription the account was already paying for survives, the second is
    # cancelled at Stripe and every cent it took goes back, and the customer
    # never loses paid access while it happens.
    it 'cancels a second completed Checkout, refunds what it charged and keeps the live subscription' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_c,
                                          stripe_subscription_id: subscription_a, quantity: 1)
      collected = paid_invoice(subscription_c, amount: 1000)

      stub_subscription(subscription_a, 'subscription-active', { 'created' => 1_000 })
      stub_duplicate(subscription_c, 'subscription-trialing-checkout', { 'created' => 2_000 }, invoice: collected)
      cancel_call = stub_cancel(subscription_c, 'subscription-trialing-checkout', invoice: collected)
      stub_invoice_list(subscription_c, [collected])
      refund_call = stub_refund("pi_#{subscription_c}", amount: 1000)

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: checkout_body(account.id))
      drain_stripe_jobs

      expect(cancel_call).to have_been_requested
      expect(refund_call).to have_been_requested
      # The row never moves onto the duplicate, and no debt is left behind.
      expect(row.reload).to have_attributes(stripe_subscription_id: subscription_a, access_state: 'active',
                                            refund_owed_subscription_id: nil)
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'processed', last_error: ProcessStripeEventJob::DUPLICATE_SUBSCRIPTION,
                            account_id: account.id)
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(body: /\$10\.00 was refunded/))

      expect_paid_access
    end

    # Q1: the customer this row holds is exactly what a Checkout click writes,
    # so the comparison has to be made against the row as it is under the
    # lock that also does the linking — not against the copy this job loaded
    # a moment earlier. Here the browser's return door gives the account its
    # Stripe customer while the webhook job is on its way to the lock; the
    # session was paid by a different one, and the row the lock re-reads is
    # what says so.
    it 'refuses a session for a customer the row gained after the job loaded it' do
      row = cancelled_row(customer: customer_a)
      row.update_columns(stripe_customer_id: nil)

      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      stub_duplicate(subscription_c, 'subscription-trialing-checkout')
      allow(ErrorReport).to receive(:warning)

      # The browser door's write, landing while this job waits for the lock.
      allow(StripeBilling::Linker).to receive(:with_account_lock).and_wrap_original do |original, record, &block|
        AccountSubscription.where(id: record.id).update_all(stripe_customer_id: customer_a)

        original.call(record, &block)
      end

      post_stripe_event(nil, body: checkout_body(account.id))
      drain_stripe_jobs

      expect(row.reload).to have_attributes(stripe_customer_id: customer_a, stripe_subscription_id: nil,
                                            access_state: 'cancelled')
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::CUSTOMER_MISMATCH,
                            account_id: account.id)

      expect_free_plan
    end

    # Q1, the last word: two rows that hold no customer yet can both pass the
    # check and race for the same Stripe customer, and the unique index
    # refuses whichever write lands second. That is the same fact the check
    # was looking for, learned a moment later — so it ends in the same
    # verdict, acknowledged and reported, instead of a failed job that spends
    # five retries walking into the same wall.
    it 'turns a race for one Stripe customer into a verdict rather than a failed event' do
      other = create(:account)
      other_row = create(:account_subscription, account: other, access_state: 'cancelled', status: 'none',
                                                quantity: 1)

      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      allow(ErrorReport).to receive(:warning)

      # The other account's row takes the customer between the check and the
      # write — exactly the gap the database is left to settle.
      allow(StripeBilling::Linker).to receive(:link_and_apply!).and_wrap_original do |original, *args, **kwargs|
        AccountSubscription.where(id: other_row.id).update_all(stripe_customer_id: customer_c)

        original.call(*args, **kwargs)
      end

      post_stripe_event(nil, body: checkout_body(account.id))
      drain_stripe_jobs

      expect(AccountSubscription.find_by(account_id: account.id))
        .to have_attributes(stripe_customer_id: nil, stripe_subscription_id: nil)
      # It got as far as the write — this is the database's refusal, not the
      # pre-check's, which never asks Stripe anything at all. (The other
      # row's grab is undone with the rest of the rolled-back attempt; at
      # Stripe, and on the next delivery, it is real.)
      expect(a_request(:get, subscription_url(subscription_c))).to have_been_made
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::CUSTOMER_MISMATCH,
                            account_id: account.id)
      expect(ErrorReport).to have_received(:warning)
        .with(/could not be matched to account #{account.id}/, hash_including(account_id: account.id))

      expect_free_plan
    end

    # M2: blank is not a match either. A session that names NO customer at
    # all, arriving for a row that holds one, is refused exactly like a
    # session naming somebody else's — the browser return door has always
    # required an exact match, and letting the webhook accept "none" would
    # apply a subscription to an account on nothing but a session id.
    it 'links nothing when the session names no customer at all' do
      row = cancelled_row(customer: customer_a)
      body = fixture_json(checkout_event)
      body['data']['object']['client_reference_id'] = account.id.to_s
      body['data']['object']['customer'] = nil

      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      stub_duplicate(subscription_c, 'subscription-trialing-checkout')
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: body.to_json)
      drain_stripe_jobs

      expect(row.reload).to have_attributes(access_state: 'cancelled', stripe_customer_id: customer_a,
                                            stripe_subscription_id: nil)
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::CUSTOMER_MISMATCH,
                            account_id: account.id)

      expect_free_plan
    end

    # And the customer arrives in two shapes: a bare id, or the whole object
    # when the session was expanded. Both are read the same way, so an
    # expanded session for the customer the row DOES hold is the ordinary
    # purchase and goes through.
    it 'reads the customer of an expanded session and links the subscription it bought' do
      row = cancelled_row(customer: customer_c)
      body = fixture_json(checkout_event)
      body['data']['object']['client_reference_id'] = account.id.to_s
      body['data']['object']['customer'] = { 'id' => customer_c, 'object' => 'customer' }

      stub_subscription(subscription_c, 'subscription-trialing-checkout')

      post_stripe_event(nil, body: body.to_json)
      drain_stripe_jobs

      expect(row.reload).to have_attributes(access_state: 'trialing', stripe_customer_id: customer_c,
                                            stripe_subscription_id: subscription_c)
      expect(StripeEventInbox.sole).to have_attributes(status: 'processed', last_error: nil)

      expect_paid_access
    end

    # The same rule from the side that used to reach the database. The
    # session's `client_reference_id` names THIS account — which pays for
    # itself, so its row is created on the spot — while the `customer` that
    # paid is one another account's row already holds (a reference copied
    # between environments, a session id pasted by hand). The new row holds no
    # customer yet, so the check above waved it through, and the write landed
    # on the unique index on `stripe_customer_id`: RecordNotUnique, a failed
    # event and five retries for something that can never become ours. Two
    # accounts named at once is a mismatch, decided before anything is
    # written.
    it 'refuses a session whose reference and customer name two different accounts' do
      other = create(:account)
      other_row = create(:account_subscription, account: other, access_state: 'active', status: 'active',
                                                stripe_status: 'active', stripe_customer_id: customer_c,
                                                stripe_subscription_id: subscription_b, quantity: 1)
      stub_subscription(subscription_c, 'subscription-trialing-checkout')
      stub_duplicate(subscription_c, 'subscription-trialing-checkout')
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: checkout_body(account.id))
      drain_stripe_jobs

      # Neither row moved, and nothing was even asked of Stripe.
      expect(other_row.reload)
        .to have_attributes(stripe_customer_id: customer_c, stripe_subscription_id: subscription_b)
      expect(AccountSubscription.find_by(account_id: account.id))
        .to have_attributes(stripe_customer_id: nil, stripe_subscription_id: nil)
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::CUSTOMER_MISMATCH,
                            account_id: account.id)
      expect(ErrorReport).to have_received(:warning)
        .with(/could not be matched to account #{account.id}/, hash_including(account_id: account.id))

      expect_free_plan
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

      expect_paid_access
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
      stub_invoice_list(subscription_b, [invoice])
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
               .with(headers: { 'Idempotency-Key' => "refund-duplicate-pi_#{subscription_b}" }))
        .to have_been_made
      expect(alerts.sole[:body]).to include("charge of $30.00 was refunded (re_pi_#{subscription_b})")
      expect(ErrorReport).to have_received(:warning)
        .with(/Cancelled duplicate/, hash_including(refund_id: "re_pi_#{subscription_b}"))
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # C2/X2: one invoice can be settled by more than one payment (a card that
    # covered part of it, then another). Refunding "the" payment returns half
    # the money and tells the operator the whole charge went back. Each of
    # those payments states what IT paid, which is how the invoice is split
    # between them.
    it 'refunds every payment that settled the duplicate\'s invoice, and states the true total' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      intents = ["pi_first_#{subscription_b}", "pi_second_#{subscription_b}"]
      invoice = paid_invoice(subscription_b, amount: 3000,
                                             payments: intents.map { |intent| { intent:, amount: 1500 } })
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      intents.each { |intent| stub_refund(intent, amount: 1500) }

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).to have_been_made.twice

      intents.each do |intent|
        expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
                 .with(headers: { 'Idempotency-Key' => "refund-duplicate-#{intent}" }))
          .to have_been_made
      end

      expect(alerts.sole[:body]).to include('charge of $30.00 was refunded')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # The reverse of M2, and the one that hands money away rather than
    # keeping it: one invoice settled by TWO payments, each of which sits on
    # a big card charge that was also paying for something else. Giving each
    # payment the whole invoice recorded $30 owed twice over, each refund was
    # capped only by what its own charge still held (plenty), and the
    # end-of-refund check only ever rejected coming up SHORT — so $60 went
    # back against $30 collected. Each payment may only return what it
    # itself took.
    it 'returns one invoice settled by two payments once over, not once per payment' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      intents = ["pi_shared_one_#{subscription_b}", "pi_shared_two_#{subscription_b}"]
      invoice = paid_invoice(subscription_b, amount: 3000,
                                             payments: intents.map { |intent| { intent:, amount: 1500 } })
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      # Each charge took $50 — this invoice's $15 and $35 of somebody else's
      # business — so nothing but the debt itself limits what could go out.
      intents.each { |intent| stub_refund(intent, amount: 1500, charge_amount: 5000) }

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).to have_been_made.twice

      intents.each do |intent|
        expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
                 .with(body: hash_including('payment_intent' => intent, 'amount' => '1500')))
          .to have_been_made
      end

      # The whole invoice against a single payment is the bug.
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('amount' => '3000'))).not_to have_been_made
      expect(alerts.sole[:body]).to include('charge of $30.00 was refunded')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # N4, the short half. One invoice, two payments, and one of those two
    # payments has already had part of its charge sent back (an operator
    # putting a complaint right, an attempt of ours past Stripe's 24-hour
    # window). What that payment owes is what IT took, and what may still be
    # sent is what is left of it — $15 owed, $5 already back, $10 to go —
    # while the other payment is returned in full. Reading the debt off the
    # invoice instead would have sent $30 twice over; reading the remainder
    # off the charge alone would have sent $15 against a $10 obligation.
    it 'sends each payment of a split invoice only the remainder it still owes' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      whole = "pi_whole_#{subscription_b}"
      part = "pi_part_#{subscription_b}"
      invoice = paid_invoice(subscription_b, amount: 3000,
                                             payments: [{ intent: whole, amount: 1500 },
                                                        { intent: part, amount: 1500 }])
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      # Both charges are $50 — this invoice's $15 each and $35 of somebody
      # else's business — so nothing but the debt itself limits what could
      # go out, and $5 of the second one has already come back.
      stub_refund(whole, amount: 1500, charge_amount: 5000)
      stub_refund(part, amount: 1000, charge_amount: 5000, refunded: 500)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).to have_been_made.twice
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('payment_intent' => whole, 'amount' => '1500'))).to have_been_made
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('payment_intent' => part, 'amount' => '1000'))).to have_been_made
      # Handing each payment the whole invoice is the bug: the charges behind
      # them are big enough that nothing else would have stopped it.
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('amount' => '3000'))).not_to have_been_made
      # $5 already back plus $25 now is the $30 the invoice collected, and
      # the customer is told the true figure.
      expect(alerts.sole[:body]).to include('charge of $25.00 was refunded')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # N5. The duplicate's $30 was settled by a card charge of $60 that was
    # also paying for something else entirely, and $40 of THAT charge has
    # already been refunded — most of it nothing to do with this duplicate.
    # What counts against this debt is only ever what this debt was owed, so
    # the $30 is square: nothing more may be sent, and nothing is wrong.
    # Counting the whole $40 as "returned against $30 collected" made the
    # totals disagree and failed the event forever, paging an operator every
    # five retries about money that was never missing.
    it 'counts only what it was owed as returned when a shared charge was refunded past it' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      shared = "pi_over_refunded_#{subscription_b}"
      invoice = paid_invoice(subscription_b, amount: 3000, payment_intent: shared)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      cancel_call = stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      stub_payment_intent(shared, amount: 6000, refunded: 4000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      # No refund stub is registered at all: an attempt would be a failed
      # connection, not a quiet pass.
      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('charges of $30.00 had already been returned')
      expect(alerts.sole[:body]).not_to include('REFUND FAILED')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # And when several payments settled an invoice but one of them does not
    # say what it took, there is no honest split to make. Splitting evenly,
    # or handing each the invoice total, both move real money on a guess —
    # so nothing is sent and a person is told, exactly as for an invoice that
    # names no payment at all.
    it 'refuses to refund an invoice whose payments do not say what each of them paid' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      intents = ["pi_silent_one_#{subscription_b}", "pi_silent_two_#{subscription_b}"]
      invoice = paid_invoice(subscription_b, amount: 3000,
                                             payments: [{ intent: intents.first, amount: 1500 },
                                                        { intent: intents.last, amount: nil }])
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      cancel_call = stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      intents.each { |intent| stub_refund(intent, amount: 3000, charge_amount: 5000) }

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable,
                        /collected 3000 through 2 payments and at least one of them states no amount/)
      # The double billing still stops; only the money waits for a person.
      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      expect(inbox.reload.status).to eq('failed')
    end

    # M1: the same refusal, in the direction that used to move money first
    # and complain afterwards. Two payments settled a $30 invoice and state
    # $10 and $15 between them — $5 short of what Stripe says the invoice
    # collected. The allocation was accepted, both stated parts were
    # refunded, and only the end-of-refund total noticed the gap and raised:
    # $25 was already gone, could not be un-refunded, and every nightly
    # retry re-read the same understated split and refused again. An
    # allocation that does not add up is refused BEFORE any refund exists.
    it 'refuses an invoice whose payments claim less than it collected, before any money moves' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      intents = ["pi_short_one_#{subscription_b}", "pi_short_two_#{subscription_b}"]
      invoice = paid_invoice(subscription_b, amount: 3000,
                                             payments: [{ intent: intents.first, amount: 1000 },
                                                        { intent: intents.last, amount: 1500 }])
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      cancel_call = stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      # Registered so both refunds COULD be made: the point is that neither
      # is, not that Stripe would have refused them.
      intents.each { |intent| stub_refund(intent, amount: 1500, charge_amount: 1500) }

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable,
                        /collected 3000 but its 2 payments claim 2500 between them/)
      # The double billing still stops; not a cent has moved.
      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      expect(inbox.reload.status).to eq('failed')
    end

    # M3's harder half. The $30 this duplicate collected sits on a $60 charge
    # shared with other business, and an operator has already put $10 of it
    # back. What is still OWED is $20 — but the cap used to be read off the
    # charge alone ($60 taken, $10 returned, $50 available), so the app
    # offered the full $30 and $40 went back against a $30 debt. The
    # shortfall check waved it through because it only ever looked for too
    # little.
    it 'sends only what is still owed on a shared charge an operator has already partly refunded' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      shared = "pi_part_refunded_#{subscription_b}"
      invoice = paid_invoice(subscription_b, amount: 3000, payment_intent: shared)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      stub_refund(shared, amount: 2000, charge_amount: 6000, refunded: 1000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).to have_been_made.once
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('payment_intent' => shared, 'amount' => '2000'))).to have_been_made
      # $10 already back plus $20 now is the $30 the duplicate collected —
      # never the $30 the charge could still have given.
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('amount' => '3000'))).not_to have_been_made
      expect(alerts.sole[:body]).to include('charge of $20.00 was refunded')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # X2's other half: a duplicate nobody noticed for three months charged
    # three times. Only its LATEST invoice used to be looked at, so two
    # months of somebody else's money stayed with us.
    it 'refunds every cycle a duplicate collected, not only its last one' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      older = paid_invoice(subscription_b, amount: 1000, id: 'in_cycle_one', payment_intent: 'pi_cycle_one')
      latest = paid_invoice(subscription_b, amount: 1000, id: 'in_cycle_two', payment_intent: 'pi_cycle_two')
      stub_duplicate(subscription_b, 'subscription-active', invoice: latest)
      stub_cancel(subscription_b, invoice: latest)
      stub_invoice_list(subscription_b, [older, latest])
      stub_refund('pi_cycle_one', amount: 1000)
      stub_refund('pi_cycle_two', amount: 1000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).to have_been_made.twice
      expect(alerts.sole[:body]).to include('charge of $20.00 was refunded')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
    end

    # L1: the subscription that LOSES the survivor policy is not always the
    # new one. A customer whose card failed keeps a `past_due` subscription
    # that has billed honestly for a year; a healthy new one appears and wins
    # on health. Cancelling the old one is right — refunding the year it
    # legitimately charged is emphatically not, and no field on a Stripe
    # invoice says how much of one part-finished cycle the two overlapped.
    # So the older loser is cancelled under a DIFFERENT marker, nothing is
    # sent back automatically, and a person is handed the two subscriptions
    # and the last invoice the cancelled one collected.
    it 'cancels an older loser under the manual marker and refunds none of the year it billed honestly' do
      row = create(:account_subscription, account:, access_state: 'past_due', status: 'past_due',
                                          stripe_status: 'past_due', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      sick = { 'id' => subscription_a, 'status' => 'past_due', 'created' => 1_000 }

      history = Array.new(11) do |cycle|
        paid_invoice(subscription_a, amount: 3000, id: "in_hist_#{cycle}",
                                     payment_intent: "pi_hist_#{cycle}", created: 1_100 + cycle)
      end
      latest = paid_invoice(subscription_a, amount: 3000, id: 'in_latest',
                                            payment_intent: 'pi_latest', created: 1_900)

      stub_subscription(subscription_a, 'subscription-active', sick)
      stub_duplicate(subscription_a, 'subscription-active', sick)
      stub_duplicate(subscription_b, 'subscription-active', { 'created' => 2_000 })
      stub_invoice_list(subscription_a, history + [latest])
      cancel_call = stub_cancel(subscription_a, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)
      # Registered so a refund could be made; the point is that none is.
      stub_refund('pi_latest', amount: 3000)

      arrival = fixture_json('event-customer.subscription.updated-active')
      arrival['data']['object']['id'] = subscription_b
      arrival['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: arrival.to_json)
      drain_stripe_jobs

      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('manual refund review')
      expect(alerts.sole[:body]).to include(subscription_b)
      expect(alerts.sole[:body]).to include('in_latest $30.00')
      expect(alerts.sole[:body]).not_to include('Its charge')
      expect(alerts.sole[:body]).not_to include('$360.00')
      expect(row.reload.stripe_subscription_id).to eq(subscription_b)
      expect(StripeEventInbox.sole).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # N7: the automatic marker is the one that moves money, so it has to be
    # earned. Here the survivor comes back from Stripe with no `created` at
    # all — a field rename, a trimmed object, a caller that forgot to pass a
    # survivor — so nothing can show the loser was the newer one. The
    # comparison is unproven, and an unproven comparison never refunds: the
    # duplicate is still cancelled, under the MANUAL marker, and a person is
    # handed the decision.
    it 'cancels under the manual marker, refunding nothing, when the survivor has no creation time' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      collected = paid_invoice(subscription_a, amount: 3000, id: 'in_only')

      stub_subscription(subscription_a, 'subscription-active', { 'created' => 2_000 })
      stub_duplicate(subscription_a, 'subscription-active', { 'created' => 2_000 }, invoice: collected)
      stub_duplicate(subscription_b, 'subscription-active', { 'created' => nil })
      stub_invoice_list(subscription_a, [collected])
      cancel_call = stub_cancel(subscription_a, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)
      # Registered so a refund could be made; the point is that none is.
      stub_refund("pi_#{subscription_a}", amount: 3000)

      arrival = fixture_json('event-customer.subscription.updated-active')
      arrival['data']['object']['id'] = subscription_b
      arrival['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: arrival.to_json)
      drain_stripe_jobs

      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('manual refund review')
      expect(row.reload.stripe_subscription_id).to eq(subscription_b)
      expect(StripeEventInbox.sole).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # The marker write carries a STABLE idempotency key and a body that
    # timestamps itself, so a retry of a half-finished attempt (the marker
    # landed, the cancel behind it did not) sends the same key with a
    # different clock — and Stripe refuses that outright. Every retry inside
    # Stripe's 24-hour window then failed identically, so the duplicate was
    # never cancelled and went on charging until the retries ran out.
    #
    # The retry has to CONVERGE instead: the refusal means the marker is
    # already written, so it is read back off the subscription and IT governs
    # the rest of the pass. That matters for the money, which is why the two
    # attempts are made to disagree here — the first cannot read the
    # survivor's creation time and writes the MANUAL marker; the second can,
    # and would choose the automatic (refunding) one. The stored marker wins,
    # the duplicate is cancelled, and the $30 it collected is still a
    # person's decision.
    it 'converges on the marker it already wrote when a retry is refused as a repeat' do
      row = create(:account_subscription, account:, access_state: 'past_due', status: 'past_due',
                                          stripe_status: 'past_due', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      collected = paid_invoice(subscription_a, amount: 3000, id: 'in_only')
      manual = StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER
      json = { 'Content-Type' => 'application/json' }
      attempt = 1

      # The row's own subscription: in dunning, so the healthy newcomer wins
      # the survivor policy on both attempts however old either one is.
      sick = { 'id' => subscription_a, 'status' => 'past_due', 'created' => 2_000 }

      stub_subscription(subscription_a, 'subscription-active', sick)
      stub_invoice_list(subscription_a, [collected])
      stub_refund("pi_#{subscription_a}", amount: 3000)

      # The duplicate, re-read on every attempt — and on the retry it comes
      # back carrying the marker the first attempt managed to write.
      stub_request(:get, subscription_url(subscription_a))
        .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND))
        .to_return do
          body = fixture_json('subscription-active').merge(sick).merge('latest_invoice' => collected)
          body = body.merge(marked_by_us(manual, fixture: 'subscription-active')) if attempt > 1

          { status: 200, body: body.to_json, headers: json }
        end

      # The survivor. Its creation time is missing on the first attempt
      # (nothing is proven, so the manual marker stands) and readable on the
      # retry (which would earn the automatic one).
      stub_request(:get, subscription_url(subscription_b))
        .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND))
        .to_return do
          body = fixture_json('subscription-active')
                 .merge('id' => subscription_b, 'status' => 'active',
                        'created' => (attempt == 1 ? nil : 1_000),
                        'latest_invoice' => unpaid_invoice(subscription_b))

          { status: 200, body: body.to_json, headers: json }
        end

      # The marker write: it lands the first time and is refused as a repeat
      # of the same key with different parameters the second.
      mark_call = stub_request(:post, subscription_url(subscription_a))
                  .with(headers: { 'Idempotency-Key' => "mark-duplicate-#{subscription_a}" })
                  .to_return do
                    if attempt == 1
                      { status: 200, body: { id: subscription_a, object: 'subscription' }.to_json, headers: json }
                    else
                      { status: 400,
                        body: { error: { type: 'idempotency_error', code: 'idempotency_key_in_use',
                                         message: 'Keys for idempotent requests can only be used with the ' \
                                                  'same parameters they were first used with.' } }.to_json,
                        headers: json }
                    end
                  end

      # The cancel, stubbed ONLY for the manual marker: a pass that cancelled
      # under the automatic one would find no stub at all.
      cancel_call = stub_request(:delete, subscription_url(subscription_a))
                    .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND,
                                                'cancellation_details' => { 'comment' => manual }))
                    .to_return do
                      if attempt == 1
                        { status: 400,
                          body: { error: { type: 'invalid_request_error', code: 'parameter_invalid',
                                           message: 'Stripe is having a bad day' } }.to_json,
                          headers: json }
                      else
                        { status: 200,
                          body: fixture_json('subscription-canceled')
                                .merge('id' => subscription_a, 'latest_invoice' => collected)
                                .merge(marked_by_us(manual, fixture: 'subscription-canceled')).to_json,
                          headers: json }
                      end
                    end

      arrival = fixture_json('event-customer.subscription.updated-active')
      arrival['data']['object']['id'] = subscription_b
      arrival['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: arrival.to_json)

      inbox = StripeEventInbox.sole

      expect { ProcessStripeEventJob.new.perform(inbox.id) }.to raise_error(Stripe::InvalidRequestError)
      expect(inbox.reload.status).to eq('failed')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)

      # An hour later Sidekiq tries again, and the marker body it would send
      # now carries a different timestamp.
      attempt = 2

      travel(1.hour) { ProcessStripeEventJob.new.perform(inbox.id) }

      expect(cancel_call).to have_been_requested.twice
      expect(mark_call).to have_been_requested.twice
      # Never re-issued under a made-up key: the marker already written is
      # the one that governs, and it was read back rather than overwritten.
      expect(a_request(:post, subscription_url(subscription_a))).to have_been_made.twice
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('manual refund review')
      expect(row.reload.stripe_subscription_id).to eq(subscription_b)
      expect(inbox.reload).to have_attributes(status: 'processed',
                                              last_error: ProcessStripeEventJob::DUPLICATE_SUBSCRIPTION)

      expect_paid_access
    end

    # M2: Stripe lets ONE card charge settle several invoices. Refunding per
    # invoice sends the same charge back twice, under two different
    # idempotency keys so Stripe cannot merge them — either money out twice
    # or an event that fails forever. One PaymentIntent is one debt and gets
    # exactly one refund, for what those invoices collected through it.
    it 'sends one refund for the one payment that settled two of the duplicate\'s invoices' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      shared = "pi_shared_#{subscription_b}"
      first = paid_invoice(subscription_b, amount: 3000, id: 'in_shared_one', payment_intent: shared, created: 1_100)
      second = paid_invoice(subscription_b, amount: 3000, id: 'in_shared_two', payment_intent: shared, created: 1_200)

      stub_duplicate(subscription_b, 'subscription-active', invoice: second)
      stub_cancel(subscription_b, invoice: second)
      stub_invoice_list(subscription_b, [first, second])
      stub_refund(shared, amount: 6000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).to have_been_made.once
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('amount' => '6000'),
                     headers: { 'Idempotency-Key' => "refund-duplicate-#{shared}" })).to have_been_made
      expect(alerts.sole[:body]).to include('charge of $60.00 was refunded')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')

      expect_paid_access
    end

    # M3: only the part of a charge that has NOT already come back may be
    # sent. An operator who refunded $10 of a $30 charge by hand leaves $20
    # outstanding — asking Stripe for the whole $30 again is refused by
    # Stripe and would tell the customer $30 went back when $20 did.
    it 'refunds only the remainder of a charge somebody has already partly refunded' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      invoice = paid_invoice(subscription_b, amount: 3000)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      stub_refund("pi_#{subscription_b}", amount: 2000, charge_amount: 3000, refunded: 1000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('amount' => '2000'))).to have_been_made.once
      expect(alerts.sole[:body]).to include('charge of $20.00 was refunded')
      expect(alerts.sole[:body]).not_to include('$30.00')
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')
    end

    # L1(b): a charge somebody already put back — an operator refunding by
    # hand, or an attempt of ours whose Stripe idempotency key has since
    # expired — counts as returned. Asking for it again would either error or
    # pay the money out twice, and the customer must not be told a refund was
    # made when none was.
    it 'counts a charge that has already been refunded as returned and does not refund it again' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      invoice = paid_invoice(subscription_b, amount: 3000)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      stub_payment_intent("pi_#{subscription_b}", amount: 3000, refunded: 3000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)
      drain_stripe_jobs

      expect(a_request(:delete, subscription_url(subscription_b))).to have_been_made
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).not_to include('was refunded')
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed')
    end

    # L3: three cycles to return, and Stripe fails on the second. The money
    # already sent back is real but the transaction rolled back, so the retry
    # must not re-send it — it re-reads each charge, skips the one that is
    # already square and finishes the other two.
    it 'finishes a refund that failed part-way without returning the same payment twice' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      invoices = (1..3).map do |cycle|
        paid_invoice(subscription_b, amount: 1000, id: "in_cycle_#{cycle}", payment_intent: "pi_cycle_#{cycle}")
      end

      stub_duplicate(subscription_b, 'subscription-active', invoice: invoices.last)
      stub_cancel(subscription_b, invoice: invoices.last)
      stub_invoice_list(subscription_b, invoices)

      # The first payment comes back on attempt one; on the retry Stripe says
      # so, and the app leaves it alone.
      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/payment_intents/pi_cycle_1})
        .to_return({ status: 200, body: payment_intent_body('pi_cycle_1', amount: 1000, refunded: 0),
                     headers: { 'Content-Type' => 'application/json' } },
                   { status: 200, body: payment_intent_body('pi_cycle_1', amount: 1000, refunded: 1000),
                     headers: { 'Content-Type' => 'application/json' } })
      stub_payment_intent('pi_cycle_2', amount: 1000)
      stub_payment_intent('pi_cycle_3', amount: 1000)

      # Registered by hand, so the sequenced charge above is not overwritten.
      first_refund = stub_request(:post, 'https://api.stripe.com/v1/refunds')
                     .with(body: hash_including('payment_intent' => 'pi_cycle_1'))
                     .to_return(status: 200,
                                body: { id: 're_pi_cycle_1', object: 'refund', amount: 1000,
                                        currency: 'usd' }.to_json,
                                headers: { 'Content-Type' => 'application/json' })
      # The second refund fails once, then works. (A 400 rather than a 500:
      # the gem retries a 500 itself, and this is about OUR retry.)
      stub_request(:post, 'https://api.stripe.com/v1/refunds')
        .with(body: hash_including('payment_intent' => 'pi_cycle_2'))
        .to_return({ status: 400,
                     body: { error: { type: 'invalid_request_error',
                                      message: 'Stripe is having a bad day' } }.to_json,
                     headers: { 'Content-Type' => 'application/json' } },
                   { status: 200, body: { id: 're_pi_cycle_2', object: 'refund', amount: 1000,
                                          currency: 'usd' }.to_json,
                     headers: { 'Content-Type' => 'application/json' } })
      stub_refund('pi_cycle_3', amount: 1000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }.to raise_error(Stripe::StripeError)
      expect(first_refund).to have_been_requested.once
      expect(inbox.reload.status).to eq('failed')

      # The Sidekiq retry.
      ProcessStripeEventJob.new.perform(inbox.id)

      expect(first_refund).to have_been_requested.once
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('payment_intent' => 'pi_cycle_2'))).to have_been_made.twice
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('payment_intent' => 'pi_cycle_3'))).to have_been_made.once
      expect(alerts.last[:body]).to include('charge of $20.00 was refunded')
      expect(inbox.reload.status).to eq('processed')
    end

    # L1(c): money never leaves automatically beyond a cap, counted per
    # PAYMENT because that is what a refund is made against. A duplicate
    # owing more payments than the app will return unattended is still
    # cancelled — the double billing stops — but the money waits for a
    # person, who hears about it through the loud path. And once that person
    # has refunded them by hand the retry converges: nothing more is sent,
    # and the note says the charges had already been returned rather than
    # claiming nothing was ever charged twice.
    it 'cancels but refuses to refund past the payment cap, then converges once a person has refunded by hand' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      cycles = (1..(StripeBilling::Linker::DUPLICATE_REFUND_MAX_PAYMENTS + 1)).to_a
      invoices = cycles.map do |cycle|
        paid_invoice(subscription_b, amount: 3000, id: "in_cycle_#{cycle}",
                                     payment_intent: "pi_cycle_#{cycle}", created: 1_000 + cycle)
      end

      stub_duplicate(subscription_b, 'subscription-active', invoice: invoices.last)
      cancel_call = stub_cancel(subscription_b, invoice: invoices.last)
      stub_invoice_list(subscription_b, invoices)
      cycles.each { |cycle| stub_refund("pi_cycle_#{cycle}", amount: 3000) }

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable,
                        /needs manual review: 4 payments, \$120\.00 still to return/)
      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      expect(inbox.reload.status).to eq('failed')

      # The operator refunds all four in the dashboard. Stripe now reports
      # the duplicate as cancelled by us, with nothing left on any charge.
      marked = marked_by_us
      stub_duplicate(subscription_b, 'subscription-canceled', marked, invoice: invoices.last)
      cycles.each { |cycle| stub_payment_intent("pi_cycle_#{cycle}", amount: 3000, refunded: 3000) }

      ProcessStripeEventJob.new.perform(inbox.id)

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.last[:body]).to include('charges of $120.00 had already been returned')
      expect(alerts.last[:body]).not_to include('Nothing was charged twice')
      expect(inbox.reload.status).to eq('processed')
    end

    # Q3: a refund the app refuses on the ORDINARY duplicate path re-raises,
    # and that raise rolls back everything the lock's transaction wrote. The
    # cancellation at Stripe does not roll back — so without this the row is
    # left knowing nothing about a dead, marked subscription it never named,
    # and once the event's five retries are spent nothing points at the money
    # at all. The debt is written onto the row after the rollback, which is
    # what brings the nightly sweep back to it.
    it 'records the debt of a duplicate it cancelled but could not refund' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      cycles = (1..(StripeBilling::Linker::DUPLICATE_REFUND_MAX_PAYMENTS + 1)).to_a
      invoices = cycles.map do |cycle|
        paid_invoice(subscription_b, amount: 3000, id: "in_cycle_#{cycle}",
                                     payment_intent: "pi_cycle_#{cycle}", created: 1_000 + cycle)
      end

      stub_duplicate(subscription_b, 'subscription-active', invoice: invoices.last)
      cancel_call = stub_cancel(subscription_b, invoice: invoices.last)
      stub_invoice_list(subscription_b, invoices)
      cycles.each { |cycle| stub_payment_intent("pi_cycle_#{cycle}", amount: 3000) }

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable, /needs manual review: 4 payments/)
      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(inbox.reload.status).to eq('failed')
      # The row kept the subscription it was already paying for, and now also
      # knows what is owed on the one that was cancelled.
      expect(row.reload).to have_attributes(stripe_subscription_id: subscription_a,
                                            refund_owed_subscription_id: subscription_b)
    end

    # T3: telling somebody about the refusal is best effort; the refusal
    # itself is not. Here the operator mail blows up while the duplicate's
    # failure is being reported — and that exception used to replace the
    # original error on its way out, taking with it the only record of which
    # subscription's money is owed. The debt is written onto the error before
    # anything talks to the outside world.
    it 'still records the debt when telling the operator about it fails' do
      row = cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      cycles = (1..(StripeBilling::Linker::DUPLICATE_REFUND_MAX_PAYMENTS + 1)).to_a
      invoices = cycles.map do |cycle|
        paid_invoice(subscription_b, amount: 3000, id: "in_cycle_#{cycle}",
                                     payment_intent: "pi_cycle_#{cycle}", created: 1_000 + cycle)
      end

      stub_duplicate(subscription_b, 'subscription-active', invoice: invoices.last)
      cancel_call = stub_cancel(subscription_b, invoice: invoices.last)
      stub_invoice_list(subscription_b, invoices)
      cycles.each { |cycle| stub_payment_intent("pi_cycle_#{cycle}", amount: 3000) }

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      allow(ErrorReport).to receive(:warning)
      allow(OperatorAlert).to receive(:deliver).and_raise(Net::SMTPFatalError, 'the mail server is down')

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      # The error the operator sees is still the refusal, not the mailer.
      expect { ProcessStripeEventJob.new.perform(inbox.id) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable, /needs manual review: 4 payments/)
      expect(cancel_call).to have_been_requested
      expect(row.reload).to have_attributes(stripe_subscription_id: subscription_a,
                                            refund_owed_subscription_id: subscription_b)
      expect(inbox.reload.last_error).to include('RefundUnavailable')
    end

    # And only ONE such note fits on a row (the accepted limit of this
    # version): a second, different debt keeps the first — it has been owed
    # longest — and pages a person by name for the other, rather than
    # overwriting the note that the sweep is working from.
    it 'keeps the first owed refund and pages a person for a second one' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a,
                                          refund_owed_subscription_id: 'sub_owed_first', quantity: 3)
      cycles = (1..(StripeBilling::Linker::DUPLICATE_REFUND_MAX_PAYMENTS + 1)).to_a
      invoices = cycles.map do |cycle|
        paid_invoice(subscription_b, amount: 3000, id: "in_cycle_#{cycle}",
                                     payment_intent: "pi_cycle_#{cycle}", created: 1_000 + cycle)
      end

      stub_subscription(subscription_a, 'subscription-active')
      stub_duplicate(subscription_a, 'subscription-active')
      stub_duplicate(subscription_b, 'subscription-active', invoice: invoices.last)
      stub_cancel(subscription_b, invoice: invoices.last)
      stub_invoice_list(subscription_b, invoices)
      cycles.each { |cycle| stub_payment_intent("pi_cycle_#{cycle}", amount: 3000) }

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      expect { StripeBilling::Linker.link_and_apply!(row, subscription_b) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable)

      expect(row.reload.refund_owed_subscription_id).to eq('sub_owed_first')
      expect(alerts.pluck(:subject)).to include("Second unpaid duplicate refund for account #{account.id}")
      expect(alerts.last[:body]).to include("refund #{subscription_b} by hand")
    end

    # L5: a list of paid invoices we could not read to the end is not a list.
    # Refunding on it would return part of the money and call it all of it,
    # so the read is refused outright and a person is told.
    it 'refuses to refund on a paid-invoice list it could not read to the end' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      invoice = paid_invoice(subscription_b, amount: 3000)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      # Stripe keeps saying there is another page, past the app's cap.
      stub_invoice_list(subscription_b, [invoice], has_more: true)
      stub_refund("pi_#{subscription_b}", amount: 3000)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable, /more than 1000 paid invoices/)
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      expect(inbox.reload.status).to eq('failed')
    end

    # C2: a refund that comes back short is the one thing that must never
    # pass quietly — the operator mail and the customer's page would both
    # say the whole charge went back.
    it 'fails loudly when the duplicate\'s charge cannot be fully returned' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      invoice = paid_invoice(subscription_b, amount: 3000)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      # Stripe returns $15.00 of the $30.00 the invoice says it collected.
      stub_refund("pi_#{subscription_b}", amount: 1500)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }
        .to raise_error(StripeBilling::Linker::RefundUnavailable, /collected 3000 but only 1500/)
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      expect(inbox.reload.status).to eq('failed')
    end

    it 'fails loudly, rather than keeping the money quietly, when the refund cannot be made' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      invoice = paid_invoice(subscription_b, amount: 3000)
      stub_duplicate(subscription_b, 'subscription-active', invoice:)
      stub_cancel(subscription_b, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      stub_payment_intent("pi_#{subscription_b}", amount: 3000)
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
      stub_invoice_list(subscription_b, [invoice])
      stub_refund("pi_#{subscription_b}", amount: 3000)

      expect(fixture_json('subscription-canceled')['metadata'])
        .not_to have_key(StripeBilling::DUPLICATE_CANCEL_METADATA_KEY)

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
      # Review 6: a stale event gets its OWN verdict (:stale_ignored). It used
      # to share 'foreign subscription' with a stranger's purchase, which told
      # the operator the customer's own previous subscription belonged to
      # somebody else.
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::STALE_SUBSCRIPTION)
      expect(ProcessStripeEventJob::STALE_SUBSCRIPTION).not_to eq(ProcessStripeEventJob::FOREIGN_SUBSCRIPTION)

      expect_paid_access
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
      marked = marked_by_us(extra_details: { 'reason' => 'cancellation_requested' })
      stub_duplicate(subscription_b, 'subscription-canceled', marked, invoice:)
      stub_invoice_list(subscription_b, [invoice])
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
               .with(headers: { 'Idempotency-Key' => "refund-duplicate-pi_#{subscription_b}" }))
        .to have_been_made
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'processed', last_error: ProcessStripeEventJob::DUPLICATE_SUBSCRIPTION)

      expect_paid_access
    end

    # X1: the row held the LATER subscription, the earlier one won, and we
    # cancelled the later one at Stripe with our marker — then the refund
    # failed and the whole transaction rolled back, leaving the row pointing
    # at a subscription Stripe has already ended. The retry has to finish the
    # refund it owes BEFORE it moves the row on: once the row names the
    # survivor, nothing ever looks at the cancelled one again and the money
    # stays with us.
    it 'finishes the refund it owes on the subscription it already cancelled before adopting the survivor' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_b, quantity: 3)
      invoice = paid_invoice(subscription_b, amount: 3000)
      marked = marked_by_us

      stub_subscription(subscription_b, 'subscription-active', { 'created' => 2_000 })
      stub_duplicate(subscription_a, 'subscription-active', { 'created' => 1_000 })
      stub_duplicate(subscription_b, 'subscription-active', { 'created' => 2_000 }, invoice:)
      stub_cancel(subscription_b, 'subscription-canceled', marked, invoice:)
      stub_invoice_list(subscription_b, [invoice])
      stub_payment_intent("pi_#{subscription_b}", amount: 3000)
      stub_request(:post, 'https://api.stripe.com/v1/refunds')
        .to_return(status: 500, body: { error: { message: 'Stripe is having a bad day' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      expect { StripeBilling::Linker.link_and_apply!(row, subscription_a) }.to raise_error(Stripe::StripeError)
      expect(a_request(:delete, subscription_url(subscription_b))).to have_been_made
      # Rolled back: the row still names the subscription Stripe has cancelled.
      expect(row.reload.stripe_subscription_id).to eq(subscription_b)

      # The Sidekiq retry. Stripe now calls the former subscription over, and
      # our own marker on it says its refund is still ours to make.
      stub_subscription(subscription_b, 'subscription-canceled', marked.merge('id' => subscription_b))
      stub_duplicate(subscription_b, 'subscription-canceled', marked, invoice:)
      stub_subscription(subscription_a, 'subscription-active', { 'created' => 1_000 })
      refund_call = stub_refund("pi_#{subscription_b}", amount: 3000)
      WebMock.reset_executed_requests!

      outcome = StripeBilling::Linker.link_and_apply!(row.reload, subscription_a)

      expect(outcome.verdict).to eq(:adopted)
      expect(refund_call).to have_been_requested.once
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(headers: { 'Idempotency-Key' => "refund-duplicate-pi_#{subscription_b}" }))
        .to have_been_made
      expect(alerts.last[:body]).to include('$30.00')
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)

      expect_paid_access
    end

    # X1's dead end, and the reason a customer sat on the free plan while
    # their card was charged every month. The refund the row owes on its own
    # cancelled duplicate needs a PERSON — four separate payments, past what
    # the app returns unattended — and that refusal used to raise BEFORE the
    # adoption behind it. Every webhook and every nightly sweep took the same
    # path and refused the same way, so the live subscription the customer is
    # actually paying for was never applied. A refund a person owes is not a
    # reason to withhold what that person's customer bought: the operator is
    # paged exactly as loudly as before, the debt is stamped onto the dead
    # subscription at Stripe where an audit will find it (the row is about to
    # stop pointing at it, so the nightly backstop never will), and the
    # adoption goes through.
    it 'adopts the live subscription even when the refund it owes needs a person, and marks that debt' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_b, quantity: 3)
      marked = marked_by_us
      cycles = (1..(StripeBilling::Linker::DUPLICATE_REFUND_MAX_PAYMENTS + 1)).to_a
      invoices = cycles.map do |cycle|
        paid_invoice(subscription_b, amount: 3000, id: "in_owed_#{cycle}",
                                     payment_intent: "pi_owed_#{cycle}", created: 1_000 + cycle)
      end

      stub_subscription(subscription_b, 'subscription-canceled', marked.merge('id' => subscription_b))
      stub_subscription(subscription_a, 'subscription-active')
      stub_invoice_list(subscription_b, invoices)
      cycles.each { |cycle| stub_payment_intent("pi_owed_#{cycle}", amount: 3000) }
      mark_call = stub_manual_refund_owed(subscription_b)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      outcome = StripeBilling::Linker.link_and_apply!(row, subscription_a)

      expect(outcome.verdict).to eq(:adopted)
      # No refund stub is registered at all: any attempt would be a failed
      # connection, not a quiet pass.
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      expect(alerts.sole[:body]).to include('needs manual review: 4 payments')
      expect(mark_call).to have_been_requested.once
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      # And the row remembers the debt itself (Review 6 N2). The Stripe stamp
      # is for a person auditing the account; this column is what brings the
      # nightly sweep back to a subscription the row no longer names — an
      # alert is read once, and nothing else would ever look again.
      expect(row.refund_owed_subscription_id).to eq(subscription_b)

      # The whole point: the customer is paying, so the customer has the plan.
      expect_paid_access
    end

    # M1, the other half: a refusal that lands AFTER the row has adopted the
    # live subscription must leave the debt written down, whatever raised it.
    # Here the money cannot be worked out at all — the dead duplicate's
    # invoice was settled by two payments that claim $25 of the $30 it
    # collected — so nothing is sent and nobody can be told an amount. The
    # customer still gets the plan they are paying for, and the row keeps the
    # note that brings the nightly sweep back to it.
    it 'records the debt when the refund it owes cannot even be worked out' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_b, quantity: 3)
      intents = ["pi_short_one_#{subscription_b}", "pi_short_two_#{subscription_b}"]
      invoice = paid_invoice(subscription_b, amount: 3000,
                                             payments: [{ intent: intents.first, amount: 1000 },
                                                        { intent: intents.last, amount: 1500 }])

      stub_subscription(subscription_b, 'subscription-canceled', marked_by_us.merge('id' => subscription_b))
      stub_subscription(subscription_a, 'subscription-active')
      stub_invoice_list(subscription_b, [invoice])
      intents.each { |intent| stub_refund(intent, amount: 1500, charge_amount: 1500) }
      mark_call = stub_manual_refund_owed(subscription_b)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      outcome = StripeBilling::Linker.link_and_apply!(row, subscription_a)

      expect(outcome.verdict).to eq(:adopted)
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      expect(alerts.sole[:body]).to include('claim 2500 between them')
      expect(mark_call).to have_been_requested.once
      expect(row.reload).to have_attributes(stripe_subscription_id: subscription_a,
                                            refund_owed_subscription_id: subscription_b)

      expect_paid_access
    end

    # The same door, the other failure, and why the two are told apart. A
    # Stripe error is TRANSIENT — the network, an outage — and nothing about
    # it says a person must act. So it still raises: the job retries, and
    # because the row still names the dead subscription the nightly
    # settle_owed_refund! backstop can find exactly the same debt again.
    # Nothing is stamped as owed to a person either, because nobody has
    # decided that yet.
    it 'still refuses to move the row on when the refund it owes failed for a transient Stripe reason' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_b, quantity: 3)
      marked = marked_by_us
      invoice = paid_invoice(subscription_b, amount: 3000)

      stub_subscription(subscription_b, 'subscription-canceled', marked.merge('id' => subscription_b))
      stub_subscription(subscription_a, 'subscription-active')
      stub_invoice_list(subscription_b, [invoice])
      stub_payment_intent("pi_#{subscription_b}", amount: 3000)
      stub_request(:post, 'https://api.stripe.com/v1/refunds')
        .to_return(status: 500, body: { error: { message: 'Stripe is having a bad day' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      expect { StripeBilling::Linker.link_and_apply!(row, subscription_a) }.to raise_error(Stripe::StripeError)
      expect(alerts.sole[:body]).to include('REFUND FAILED — refund manually')
      # Nothing was written onto the dead subscription, and the row still
      # names it — which is what the sweep needs to try again.
      expect(a_request(:post, subscription_url(subscription_b))).not_to have_been_made
      expect(row.reload.stripe_subscription_id).to eq(subscription_b)
    end

    # The other side of the same door: a subscription that is simply over —
    # the customer cancelled it, or Stripe did — carries no marker of ours,
    # so there is nothing owed. The row adopts the newcomer and no refund is
    # ever attempted, however much that dead subscription once collected.
    it 'adopts without a refund when the subscription it held was ended by somebody else' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_b, quantity: 3)
      invoice = paid_invoice(subscription_b, amount: 3000)

      expect(fixture_json('subscription-canceled')['metadata'])
        .not_to have_key(StripeBilling::DUPLICATE_CANCEL_METADATA_KEY)

      stub_subscription(subscription_b, 'subscription-canceled', { 'id' => subscription_b })
      stub_invoice_list(subscription_b, [invoice])
      stub_refund("pi_#{subscription_b}", amount: 3000)
      stub_subscription(subscription_a, 'subscription-active')

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      outcome = StripeBilling::Linker.link_and_apply!(row, subscription_a)

      expect(outcome.verdict).to eq(:adopted)
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)

      expect_paid_access
    end

    # N1, the exploit fence. `cancellation_details.comment` is the free-text
    # box our own Customer Portal shows a customer who cancels and picks
    # "other" — so a customer can type our marker string onto their own
    # subscription and, if the app believed it, ask us to refund every
    # invoice they ever honestly paid. The marker's authority is METADATA,
    # which only a secret key can write, and this dead subscription carries
    # the comment and nothing else. Nothing goes back, nobody is paged.
    it 'refunds nothing for a dead subscription whose cancellation comment merely quotes our marker' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_b, quantity: 3)
      forged = marked_by_us(metadata: false)
      invoice = paid_invoice(subscription_b, amount: 3000)

      expect(forged.dig('cancellation_details', 'comment')).to eq(StripeBilling::DUPLICATE_CANCEL_MARKER)
      expect(forged['metadata']).not_to have_key(StripeBilling::DUPLICATE_CANCEL_METADATA_KEY)

      stub_subscription(subscription_b, 'subscription-canceled', forged.merge('id' => subscription_b))
      stub_invoice_list(subscription_b, [invoice])
      stub_refund("pi_#{subscription_b}", amount: 3000)
      stub_subscription(subscription_a, 'subscription-active')

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      outcome = StripeBilling::Linker.link_and_apply!(row, subscription_a)

      expect(outcome.verdict).to eq(:adopted)
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(alerts).to be_empty
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)

      expect_paid_access
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

      expect_paid_access
    end

    # N3: which of two live subscriptions survives is decided on whether it
    # can COLLECT before anything else. Here the row holds an `incomplete`
    # subscription on our price — an abandoned card confirmation that has
    # never taken a cent and never will — and the trialing subscription the
    # customer is actually on carries our own Checkout's account tag but sits
    # on a price we cannot read (a price swapped in the dashboard, a
    # migration nobody told the app about). Ranking "on our price" first kept
    # the incomplete one, cancelled the live trial as the duplicate and left
    # the account on a subscription that can never pay: free plan, API off.
    # Health first keeps the one that can.
    it 'keeps the subscription that is collecting over an incomplete one that merely sits on our price' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'incomplete',
                                          stripe_status: 'incomplete', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 1)
      incomplete = { 'id' => subscription_a, 'status' => 'incomplete', 'created' => 1_000 }
      collecting = fixture_json('subscription-trialing')
      collecting['items']['data'][0]['price'] = { 'id' => 'price_other_product', 'object' => 'price' }
      collecting['metadata'] = { 'esigncenter_account_id' => account.id.to_s }
      collecting = collecting.slice('items', 'metadata').merge('created' => 2_000)

      expect(StripeBilling::SubscriptionPolicy.ours?(fixture_json('subscription-trialing').merge(collecting),
                                                     account.id)).to be(true)

      stub_subscription(subscription_a, 'subscription-active', incomplete)
      stub_duplicate(subscription_a, 'subscription-active', incomplete)
      stub_duplicate(subscription_b, 'subscription-trialing', collecting)
      # Registered for BOTH, so whichever one the policy picks finds a stub
      # and the assertion — not a missing stub — is what decides the example.
      cancel_incomplete = stub_cancel(subscription_a, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)
      stub_cancel(subscription_b, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)
      stub_cancel(subscription_b)

      arrival = fixture_json('event-customer.subscription.updated-active')
      arrival['data']['object']['id'] = subscription_b
      arrival['data']['object']['customer'] = customer_a

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      post_stripe_event(nil, body: arrival.to_json)
      drain_stripe_jobs

      expect(cancel_incomplete).to have_been_requested
      expect(a_request(:delete, subscription_url(subscription_b))).not_to have_been_made
      expect(row.reload.stripe_subscription_id).to eq(subscription_b)
      expect(row.access_state).to eq('trialing')

      expect_paid_access
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

      expect_free_plan
    end

    # A1 (review 7). "Our own Checkout tagged it" is the second half of what
    # makes a subscription ours, and the tag has to be a name nobody else on
    # the Stripe account would choose. It used to be the bare `account_id` —
    # exactly what a second product sharing this Stripe account would call its
    # own tenant id — so a stranger's subscription whose tenant number happened
    # to equal one of our account ids would have been adopted, and cancelled
    # and refunded when we already held one. The bare key confers nothing now.
    it 'does not treat a foreign-price subscription tagged with the bare account_id as ours' do
      row = cancelled_row
      foreign = fixture_json('subscription-trialing')
      foreign['items']['data'][0]['price']['id'] = 'price_other_product'
      foreign['metadata'] = { 'account_id' => account.id.to_s }

      expect(StripeBilling::SubscriptionPolicy.ours?(foreign, account.id)).to be(false)

      stub_subscription(subscription_a, 'subscription-trialing', foreign.slice('items', 'metadata'))

      allow(ErrorReport).to receive(:warning)

      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(row.reload.stripe_subscription_id).to be_nil
      expect(row.access_state).to eq('cancelled')
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::FOREIGN_SUBSCRIPTION)

      expect_free_plan
    end

    # And the same tag on the same stranger cannot get it CANCELLED either:
    # the account holds its own subscription, the tagged stranger arrives as a
    # would-be duplicate, and the job refuses rather than cancelling and
    # refunding somebody else's real purchase.
    it 'never cancels a foreign-price subscription tagged with the bare account_id' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      foreign = fixture_json('subscription-active')
      foreign['items']['data'][0]['price']['id'] = 'price_other_product'
      foreign['metadata'] = { 'account_id' => account.id.to_s }
      stub_duplicate(subscription_b, 'subscription-active', foreign.slice('items', 'metadata'))

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }.to raise_error(ArgumentError, /not an EsignCenter/)
      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
    end

    # The other side of A1: our OWN tag, under the namespaced key, is still
    # enough on its own. A subscription this app sold whose price was swapped
    # in the Stripe dashboard is ours and is adopted — that is the case the
    # tag exists for (Review 6 N3), and namespacing it must not cost it.
    it 'adopts a subscription our Checkout tagged, even on a price we no longer recognise' do
      row = cancelled_row
      ours = fixture_json('subscription-trialing')
      ours['items']['data'][0]['price']['id'] = 'price_swapped_in_the_dashboard'
      ours['metadata'] = { 'esigncenter_account_id' => account.id.to_s }

      expect(StripeBilling::SubscriptionPolicy.ours?(ours, account.id)).to be(true)

      stub_subscription(subscription_a, 'subscription-trialing', ours.slice('items', 'metadata'))

      allow(ErrorReport).to receive(:warning)

      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      row.reload
      expect(row.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('trialing')
      expect(StripeEventInbox.sole).to have_attributes(status: 'processed')

      expect_paid_access
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

      stub_mark_duplicate(subscription_b)
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

    # N1, the other half: the metadata marker IS the app's memory of "we
    # ended this and we owe its money". A cancel that landed without it would
    # leave a dead subscription indistinguishable from somebody else's
    # history and the refund would be lost silently — so the marker is
    # written first, and if that write fails nothing is cancelled at all.
    it 'cancels nothing when the marker cannot be written, and fails the event loudly' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      stub_duplicate(subscription_b, 'subscription-active')
      stub_request(:post, subscription_url(subscription_b))
        .to_return(status: 500, body: { error: { message: 'Stripe is having a bad day' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
      cancel_call = stub_request(:delete, subscription_url(subscription_b))
                    .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND))
                    .to_return(status: 200, body: fixture_json('subscription-canceled').to_json,
                               headers: { 'Content-Type' => 'application/json' })

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.order(:id).last

      expect { ProcessStripeEventJob.new.perform(inbox.id) }.to raise_error(Stripe::StripeError)
      expect(a_request(:post, subscription_url(subscription_b))
               .with(headers: { 'Idempotency-Key' => "mark-duplicate-#{subscription_b}" }))
        .to have_been_made.at_least_once
      expect(cancel_call).not_to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(inbox.reload.status).to eq('failed')
    end

    # G10: "already gone" means Stripe SAID so — resource_missing, or a
    # retrieved status that is explicitly finished. A malformed answer with no
    # status is not a cancellation.
    it 'does not read a blank status as "already cancelled"' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      stub_mark_duplicate(subscription_b)
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

      # Changed by Session 7 (D43/D57): Stripe giving up on the card also
      # SUSPENDS the account, with no grace left to give — so the token is
      # refused by the account-state guard (401, and it never says why)
      # before the entitlement guard could answer 403.
      expect(account.reload.suspended_at).to be_present
      expect(account.suspension_reason).to eq('billing')

      get '/api/templates', headers: api_headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'Account is not active')
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

    # The table maps a status to a string; these two rows are the ones whose
    # meaning is easiest to get wrong, so they are driven all the way to what
    # the account may actually do. `canceling` is still fully paid until the
    # period ends; a paused subscription is not.
    it 'leaves a subscription cancelled at period end fully paid until it ends' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'none')

      described_class.apply!(row, fixture_json('subscription-active').merge('cancel_at_period_end' => true))

      expect(row.reload.access_state).to eq('canceling')

      expect_paid_access
    end

    it 'takes the paid features away the moment Stripe pauses the subscription' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active')

      described_class.apply!(row, fixture_json('subscription-active').merge('status' => 'paused'))

      expect(row.reload.access_state).to eq('suspended')
      # Changed by Session 7 (D43/D57): a paused subscription suspends the
      # account too, so its tokens meet the state guard's 401 rather than the
      # entitlement guard's 403.
      expect(account.reload.suspended_at).to be_present

      expect_free_plan(token_status: :unauthorized)
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

      # A failed event grants nothing in the meantime.
      expect_free_plan

      stub_subscription(subscription_a, 'subscription-trialing')

      described_class.new.perform(inbox.id)

      expect(inbox.reload.status).to eq('processed')
      expect(inbox.attempts).to eq(2)
      expect(inbox.last_error).to be_nil
      expect(row.reload.access_state).to eq('trialing')

      # And the SAME token that was refused a moment ago now works.
      expect_paid_access
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

    # A2 (review 7). Which worker gets an event is decided by ONE conditional
    # UPDATE, not by reading the status and then writing it. A row another
    # worker is holding right now (`processing`) is never picked up: deciding
    # that worker died belongs to the stuck-row sweep, and a second job would
    # spend one of the event's five retries for nothing.
    it 'leaves a row another worker is holding alone' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole
      # A FRESH claim: a worker took it a moment ago and is still inside its
      # Stripe call. An OLD one is a different case entirely — the sweep
      # releases that one rather than leaving it (P1) — so the age is spelled
      # out here rather than left to whatever `update!` happened to write.
      inbox.update_columns(status: StripeEventInbox::PROCESSING, attempts: 1, updated_at: Time.current)

      expect(StripeEventInbox.stale_claims).to be_empty

      expect { described_class.new.perform(inbox.id) }.not_to(change { inbox.reload.attempts })
      expect(inbox.reload.status).to eq('processing')
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
    end

    # And the window that actually happens in production: Stripe re-delivers
    # an event (or the 06:00 sweep re-enqueues one) while the first worker is
    # still inside its Stripe call. The second worker here is started from
    # inside that very call, so it arrives at the exact moment the claim is
    # held. Before the claim was a compare-and-set both workers ran the whole
    # duplicate machinery: two of the five attempts spent, the cancel sent
    # twice and the operator paged twice for one duplicate.
    it 'lets only one of two workers that pick up the same event do the work' do
      row = create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                          stripe_status: 'trialing', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 1)

      duplicate = fixture_json('event-customer.subscription.created-active')
      duplicate['data']['object']['customer'] = customer_a

      post_stripe_event(nil, body: duplicate.to_json)

      inbox = StripeEventInbox.sole
      second_worker_runs = 0

      # The row's OWN subscription is what the Linker re-fetches first; the
      # second worker is let in while that request is in flight.
      stub_request(:get, subscription_url(subscription_a))
        .with(query: hash_including('expand' => StripeBilling::SUBSCRIPTION_EXPAND))
        .to_return do |_request|
          if second_worker_runs.zero?
            second_worker_runs += 1
            described_class.new.perform(inbox.id)
          end

          { status: 200, headers: { 'Content-Type' => 'application/json' },
            body: fixture_json('subscription-trialing').merge('created' => 1_000).to_json }
        end

      stub_duplicate(subscription_a, 'subscription-trialing', { 'created' => 1_000 })
      stub_duplicate(subscription_b, 'subscription-active', { 'created' => 2_000 })
      cancel_call = stub_cancel(subscription_b)

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      described_class.new.perform(inbox.id)

      expect(second_worker_runs).to eq(1)
      # One dispatch: one attempt spent, one cancel sent, one page.
      expect(inbox.reload.attempts).to eq(1)
      expect(inbox.status).to eq('processed')
      expect(cancel_call).to have_been_requested.once
      expect(OperatorAlert).to have_received(:deliver).once
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)

      expect_paid_access
    end
  end

  describe StripeReconciliationJob do
    # The nightly sweep also asks Stripe which subscriptions each customer
    # has; unless an example is about that, the answer is "just the one".
    #
    # The sweep's resume cursor lives in Redis and outlives an example, so it
    # is cleared on both sides: a run that stopped on its budget would
    # otherwise make every later example skip rows.
    before do
      StripeReconciliationState.cursor = nil

      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions\?})
        .to_return(status: 200, body: { object: 'list', data: [] }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

    after { StripeReconciliationState.cursor = nil }

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

      expect_free_plan
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

      expect_paid_access
    end

    # C1: which of two live subscriptions survives is decided on whether it
    # can actually COLLECT, not on age alone. A customer left holding an
    # older subscription that never charged (an abandoned 3-D Secure) or one
    # Stripe has given up dunning, plus a newer one that is charging, must
    # keep the newer one — ranking age first cancels and refunds the paying
    # subscription and leaves the account on the dead one: free plan, API
    # off. Resolving between two subscriptions the Linker re-fetched under
    # the row lock is not adoption from a list: the sweep still never writes
    # a subscription the row has never heard of onto it (below).
    { 'incomplete' => 'cancelled', 'past_due' => 'past_due' }.each do |sick_status, sick_state|
      context "when the row holds an older #{sick_status} subscription and the customer has a collecting one" do
        let!(:row) do
          create(:account_subscription, account:, access_state: sick_state, status: sick_status,
                                        stripe_status: sick_status, stripe_customer_id: customer_a,
                                        stripe_subscription_id: subscription_a, quantity: 3)
        end
        let(:cancel_sick) { stub_cancel(subscription_a, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER) }
        let(:refund_healthy) { stub_refund("pi_#{subscription_b}", amount: 3000) }
        let(:report) { described_class.new.perform }

        before do
          sick = { 'id' => subscription_a, 'status' => sick_status, 'created' => 1_000 }
          invoice = paid_invoice(subscription_b, amount: 3000)

          stub_subscription(subscription_a, 'subscription-active', sick)
          stub_duplicate(subscription_a, 'subscription-active', sick)
          stub_subscription(subscription_b, 'subscription-active', { 'created' => 2_000 })
          stub_duplicate(subscription_b, 'subscription-active', { 'created' => 2_000 }, invoice:)
          stub_subscription_list(
            customer_a,
            { subscription_a => listed_subscription(subscription_a, sick_status, created: 1_000),
              subscription_b => listed_subscription(subscription_b, 'active', created: 2_000) }
          )
          stub_invoice_list(subscription_b, [invoice])
          cancel_sick
          refund_healthy

          allow(OperatorAlert).to receive(:deliver).and_return(true)
          allow(ErrorReport).to receive(:warning)

          report
        end

        it "cancels the #{sick_status} subscription and moves the account onto the one that is collecting" do
          expect(cancel_sick).to have_been_requested
          expect(a_request(:delete, subscription_url(subscription_b))).not_to have_been_made
          expect(refund_healthy).not_to have_been_requested
          expect(report.duplicates.sole).to include(account_id: account.id, cancelled: subscription_a)

          row.reload

          expect(row.stripe_subscription_id).to eq(subscription_b)
          expect(row.stripe_status).to eq('active')
          expect(row.access_state).to eq('active')
        end

        it_behaves_like 'an account with paid access'
      end
    end

    # L1 on the sweep — the path that made the unbounded refund routine. The
    # row holds a year-old `past_due` subscription with twelve paid cycles; a
    # healthy newer one wins the survivor policy, so the old one is cancelled
    # — and NONE of the twelve comes back automatically. The customer keeps
    # paid access on the survivor, and the summary hands the part-cycle
    # question to a person under its own heading. (Before this rule the sweep
    # refunded all twelve — $360 — on one summary line.)
    it 'cancels the row\'s own older subscription for manual review and refunds none of its twelve cycles' do
      row = create(:account_subscription, account:, access_state: 'past_due', status: 'past_due',
                                          stripe_status: 'past_due', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      sick = { 'id' => subscription_a, 'status' => 'past_due', 'created' => 1_000 }
      history = Array.new(11) do |cycle|
        paid_invoice(subscription_a, amount: 3000, id: "in_hist_#{cycle}",
                                     payment_intent: "pi_hist_#{cycle}", created: 1_100 + cycle)
      end
      latest = paid_invoice(subscription_a, amount: 3000, id: 'in_latest',
                                            payment_intent: 'pi_latest', created: 1_900)

      stub_subscription(subscription_a, 'subscription-active', sick)
      stub_duplicate(subscription_a, 'subscription-active', sick)
      stub_subscription(subscription_b, 'subscription-active', { 'created' => 2_000 })
      stub_duplicate(subscription_b, 'subscription-active', { 'created' => 2_000 })
      stub_subscription_list(
        customer_a,
        { subscription_a => listed_subscription(subscription_a, 'past_due', created: 1_000),
          subscription_b => listed_subscription(subscription_b, 'active', created: 2_000) }
      )
      stub_invoice_list(subscription_a, history + [latest])
      cancel_call = stub_cancel(subscription_a, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)
      stub_refund('pi_latest', amount: 3000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(cancel_call).to have_been_requested
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(report.duplicates.sole)
        .to include(account_id: account.id, cancelled: subscription_a, refunded: nil)
      expect(report.manual_refunds.sole).to include(account_id: account.id, cancelled: subscription_a)
      expect(alerts.sole[:body]).to include('manual refund review')
      expect(alerts.sole[:body]).to include('in_latest $30.00')
      expect(alerts.sole[:body]).not_to include('$360.00')
      expect(row.reload.stripe_subscription_id).to eq(subscription_b)

      expect_paid_access
    end

    # L2: the X1 rollback left the row naming a subscription WE cancelled as
    # a duplicate and never refunded, and every Sidekiq retry failed. Nothing
    # else will ever look at it — a dead subscription raises no more webhooks
    # — so the sweep is the last thing standing between the customer and
    # money we kept. It settles the debt and names it in the one summary.
    it 'settles a refund owed on the marked-dead subscription the row still names' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      marked = marked_by_us
      invoice = paid_invoice(subscription_a, amount: 3000)

      stub_subscription(subscription_a, 'subscription-canceled', marked)
      stub_subscription(subscription_b, 'subscription-active', { 'created' => 2_000 })
      stub_subscription_list(customer_a,
                             { subscription_b => listed_subscription(subscription_b, 'active', created: 2_000) })
      stub_invoice_list(subscription_a, [invoice])
      refund_call = stub_refund("pi_#{subscription_a}", amount: 3000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(refund_call).to have_been_requested.once
      expect(report.settled.sole)
        .to include(account_id: account.id, subscription: subscription_a, refunded: '$30.00')
      expect(alerts.sole[:body]).to include("refund settled: $30.00 for #{subscription_a}")
      # Still no adoption: the live one is only named for a person.
      expect(report.unlinked.sole).to include(account_id: account.id, subscription: subscription_b)
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('cancelled')

      expect_free_plan
    end

    # N1, the exploit fence on the sweep door: the same dead subscription,
    # but the marker string is only in `cancellation_details.comment` — the
    # field our own Customer Portal invites the customer to fill in when they
    # cancel and choose "other". The authority is metadata, which they cannot
    # write, and there is none here. Their honestly paid history stays paid;
    # the night stays quiet.
    it 'settles nothing for a dead subscription whose cancellation comment merely quotes our marker' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                          stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      forged = marked_by_us(metadata: false)
      invoice = paid_invoice(subscription_a, amount: 3000)
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-canceled').merge(forged))

      expect(forged.dig('cancellation_details', 'comment')).to eq(StripeBilling::DUPLICATE_CANCEL_MARKER)
      expect(forged['metadata']).not_to have_key(StripeBilling::DUPLICATE_CANCEL_METADATA_KEY)

      stub_subscription(subscription_a, 'subscription-canceled', forged)
      stub_subscription_list(customer_a, {})
      stub_invoice_list(subscription_a, [invoice])
      stub_refund("pi_#{subscription_a}", amount: 3000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(report.settled).to be_empty
      expect(report.manual_refunds).to be_empty
      expect(alerts).to be_empty
    end

    # The other half: a marked-dead subscription whose money already went
    # back owes nothing. Nothing is sent, nothing is claimed, and a quiet
    # night stays a quiet night.
    it 'issues nothing and says nothing when the owed refund has already been made' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                          stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      marked = marked_by_us
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-canceled').merge(marked))

      stub_subscription(subscription_a, 'subscription-canceled', marked)
      stub_subscription_list(customer_a, {})
      stub_invoice_list(subscription_a, [paid_invoice(subscription_a, amount: 3000)])
      stub_payment_intent("pi_#{subscription_a}", amount: 3000, refunded: 3000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(report.settled).to be_empty
      expect(alerts).to be_empty
    end

    # M4: nothing took over — the customer's other subscription is gone too,
    # so there is no survivor to measure anything against. There does not
    # need to be one: we only ever write the automatic marker on a duplicate
    # created AFTER the survivor, so the marker alone says every cycle it
    # collected is owed. Two of those cycles were settled by one card
    # charge, and one refund puts both right.
    it 'settles the whole debt of a marked-dead duplicate when nothing took over, one refund per payment' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      marked = marked_by_us
      shared = "pi_shared_#{subscription_a}"
      first = paid_invoice(subscription_a, amount: 3000, id: 'in_one', payment_intent: shared, created: 1_100)
      second = paid_invoice(subscription_a, amount: 3000, id: 'in_two', payment_intent: shared, created: 1_200)

      stub_subscription(subscription_a, 'subscription-canceled', marked)
      stub_subscription_list(customer_a, {})
      stub_invoice_list(subscription_a, [first, second])
      refund_call = stub_refund(shared, amount: 6000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(refund_call).to have_been_requested.once
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')
               .with(body: hash_including('amount' => '6000'),
                     headers: { 'Idempotency-Key' => "refund-duplicate-#{shared}" })).to have_been_made
      expect(report.settled.sole)
        .to include(account_id: account.id, subscription: subscription_a, refunded: '$60.00')
      expect(alerts.sole[:body]).to include("refund settled: $60.00 for #{subscription_a}")
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)

      expect_free_plan
    end

    # The settlement's other guard: a duplicate we cancelled under the MANUAL
    # marker is settled as far as the app is concerned. However much it
    # collected, the sweep sends nothing and says nothing — a person already
    # owns that decision, and a second alert every night is not help.
    # N2: the debt the row has already moved PAST. An earlier pass cancelled a
    # duplicate, could not return its money on its own (four separate
    # payments, more than the app sends unattended) and adopted the live
    # subscription the customer is paying for — as it must, or somebody pays
    # full price for the free plan. Nothing looks at a dead subscription
    # again: no webhook arrives about one, and the row names another now. The
    # note the Linker left on the row is what brings the sweep back to it
    # every night until the money is square — and here an operator has
    # refunded three of the four by hand, so what is left is inside the cap
    # and the app finishes it and forgets the debt.
    it 'settles the refund the row still remembers owing on a subscription it no longer names' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a,
                                          refund_owed_subscription_id: subscription_b, quantity: 3)
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-active'))

      cycles = (1..(StripeBilling::Linker::DUPLICATE_REFUND_MAX_PAYMENTS + 1)).to_a
      invoices = cycles.map do |cycle|
        paid_invoice(subscription_b, amount: 3000, id: "in_owed_#{cycle}",
                                     payment_intent: "pi_owed_#{cycle}", created: 1_000 + cycle)
      end

      stub_subscription(subscription_a, 'subscription-active')
      stub_subscription_list(customer_a, { subscription_a => 'active' })
      stub_subscription(subscription_b, 'subscription-canceled', marked_by_us.merge('id' => subscription_b))
      stub_invoice_list(subscription_b, invoices)
      # The operator has already put three of the four back by hand.
      cycles.take(3).each { |cycle| stub_payment_intent("pi_owed_#{cycle}", amount: 3000, refunded: 3000) }
      refund_call = stub_refund('pi_owed_4', amount: 3000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(refund_call).to have_been_requested.once
      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).to have_been_made.once
      expect(report.settled.sole)
        .to include(account_id: account.id, subscription: subscription_b, refunded: '$30.00')
      expect(alerts.sole[:body]).to include("refund settled: $30.00 for #{subscription_b}")
      # Square, so the row stops carrying it and the sweep stops asking.
      expect(row.reload.refund_owed_subscription_id).to be_nil
      expect(row.stripe_subscription_id).to eq(subscription_a)

      expect_paid_access
    end

    # T2: a row can owe a refund without naming any subscription at all. The
    # Checkout door records exactly that — a duplicate found on the way in,
    # cancelled, its refund refused, and nothing ever linked to the row — and
    # a sweep that only asked for rows with a subscription id walked straight
    # past those debts every night. Nothing is repaired and no duplicate is
    # decided for such a row; it is here for its money and nothing else.
    it 'settles a debt on a row that names no subscription of its own' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'none',
                                          stripe_customer_id: customer_a,
                                          refund_owed_subscription_id: subscription_b, quantity: 1)
      invoice = paid_invoice(subscription_b, amount: 3000)

      stub_subscription(subscription_b, 'subscription-canceled', marked_by_us.merge('id' => subscription_b))
      stub_invoice_list(subscription_b, [invoice])
      refund_call = stub_refund("pi_#{subscription_b}", amount: 3000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(refund_call).to have_been_requested.once
      expect(report.settled.sole)
        .to include(account_id: account.id, subscription: subscription_b, refunded: '$30.00')
      expect(row.reload.refund_owed_subscription_id).to be_nil
      # Nothing else was attempted for it: no repair, no duplicate pass.
      expect(report.repaired).to be_empty
      expect(report.errors).to be_empty
      expect(a_request(:get, %r{api\.stripe\.com/v1/subscriptions\?})).not_to have_been_made
    end

    # M3: the repair and the owed refund are not the same job, and one must
    # not take the other down with it. Stripe cannot answer for the
    # subscription this row names — an outage on that one object, a
    # subscription deleted in the dashboard — so the repair fails and is
    # reported. The debt the row remembers is on a DIFFERENT, dead
    # subscription and is re-fetched under the lock, so a stale row is no
    # reason to keep the customer's money for another night. Sharing one
    # rescue meant an account whose repair failed every night never had its
    # refund attempted at all; the duplicate pass is still skipped, because
    # that one genuinely cannot be decided on a stale row.
    it 'settles the refund the row remembers even when the repair before it failed' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a,
                                          refund_owed_subscription_id: subscription_b, quantity: 3)
      invoice = paid_invoice(subscription_b, amount: 3000)

      stub_request(:get, subscription_url(subscription_a))
        .with(query: hash_including('expand' => StripeBilling::SUBSCRIPTION_EXPAND))
        .to_return(status: 500, body: '{"error":{"message":"Stripe is having a bad day"}}',
                   headers: { 'Content-Type' => 'application/json' })
      stub_subscription_list(customer_a, { subscription_a => 'active', subscription_b => 'canceled' })
      stub_subscription(subscription_b, 'subscription-canceled', marked_by_us.merge('id' => subscription_b))
      stub_invoice_list(subscription_b, [invoice])
      refund_call = stub_refund("pi_#{subscription_b}", amount: 3000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:error)
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(refund_call).to have_been_requested.once
      expect(report.settled.sole)
        .to include(account_id: account.id, subscription: subscription_b, refunded: '$30.00')
      expect(row.reload.refund_owed_subscription_id).to be_nil
      # The repair still failed and is still counted, and the duplicate pass
      # was still skipped: nothing is cancelled on a stale row.
      expect(report.errors.size).to eq(1)
      expect(report.duplicates).to be_empty
      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
    end

    it 'sends nothing and reports nothing for a dead duplicate marked for manual review' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                          stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)
      marked = marked_by_us(StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)
      StripeBilling::SubscriptionSync.apply!(row, fixture_json('subscription-canceled').merge(marked))

      stub_subscription(subscription_a, 'subscription-canceled', marked)
      stub_subscription_list(customer_a, {})
      stub_invoice_list(subscription_a, [paid_invoice(subscription_a, amount: 3000)])
      stub_refund("pi_#{subscription_a}", amount: 3000)

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(a_request(:post, 'https://api.stripe.com/v1/refunds')).not_to have_been_made
      expect(report.settled).to be_empty
      expect(report.manual_refunds).to be_empty
      expect(alerts).to be_empty
    end

    # G12, the third case: the row's own subscription is over and the
    # customer still has a live one of ours that no row claims — somebody may
    # be paying for nothing. Adopting it is a person's decision, so the sweep
    # only names it, and the account gets nothing until a human acts.
    it 'names a live subscription no row claims, adopts nothing and grants nothing' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)

      stub_subscription(subscription_a, 'subscription-canceled')
      stub_subscription_list(customer_a, { subscription_b => 'active' })

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(report.unlinked.sole).to include(account_id: account.id, subscription: subscription_b)
      expect(report.duplicates).to be_empty
      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      expect(row.access_state).to eq('cancelled')

      expect_free_plan
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

      expect_free_plan
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

      expect_paid_access
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

      # Stored and never picked up: the enqueue was lost. Nothing holds the
      # row, so it is simply enqueued again. (The other kind of stuck row —
      # one a dead worker left `processing` — has to be released first, and
      # is pinned end to end in the two examples below.)
      stuck = StripeEventInbox.sole
      stuck.update_columns(status: 'pending', updated_at: 20.minutes.ago)

      # Both are older than StripeEventInbox::RETRY_AFTER: a `failed` row
      # inside that window still belongs to Sidekiq's own retry chain and the
      # sweep leaves it alone (C8, pinned in its own example below). What is
      # being asserted here is the budget — retries left, or spent.
      failed = StripeEventInbox.create!(stripe_event_id: 'evt_failed', event_type: 'invoice.paid',
                                        payload: '{}', status: 'failed', attempts: 2)
      exhausted = StripeEventInbox.create!(stripe_event_id: 'evt_exhausted', event_type: 'invoice.paid',
                                           payload: '{}', status: 'failed', attempts: 5)

      [failed, exhausted].each { |row| row.update_columns(updated_at: 45.minutes.ago) }

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      ProcessStripeEventJob.jobs.clear

      report = described_class.new.perform

      enqueued = ProcessStripeEventJob.jobs.map { |job| job['args'].first }

      expect(enqueued).to contain_exactly(stuck.id, failed.id)
      expect(enqueued).not_to include(exhausted.id)
      expect(report.requeued).to eq(2)
    end

    # P1 (checkpoint 7, cycle 2). A worker that dies mid-dispatch — OOM, a
    # deploy past Sidekiq's shutdown grace — leaves its row `processing` with
    # nobody working it. The claim is a compare-and-set over pending/failed,
    # so until this sweep hands the row back, every re-delivery and every
    # re-enqueue is refused: the event is lost for ever, and a lost
    # `checkout.session.completed` is a customer who paid and got nothing.
    # The claim is released as a SPENT attempt, with the reason on the row,
    # and only then is the event worked again.
    it 'releases a claim a dead worker left behind, and the event is then processed' do
      cancelled_row
      stub_subscription(subscription_a, 'subscription-trialing')
      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole
      inbox.update_columns(status: StripeEventInbox::PROCESSING, attempts: 1,
                           updated_at: (StripeEventInbox::STALE_CLAIM_AFTER + 10.minutes).ago)

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      ProcessStripeEventJob.jobs.clear

      report = described_class.new.perform

      expect(report.requeued).to eq(1)
      expect(inbox.reload.status).to eq('failed')
      expect(inbox.attempts).to eq(1)
      expect(inbox.last_error).to include('claim released by reconciliation')

      drain_stripe_jobs

      # Worked exactly once, and the row is terminal: the event is not lost.
      expect(inbox.reload.status).to eq('processed')
      expect(inbox.attempts).to eq(2)
      expect(account.reload.account_subscription.access_state).to eq('trialing')
    end

    # And the other side of the same rule: a claim that is only minutes old
    # belongs to a worker that is still inside its Stripe call. Stealing it
    # would spend a second of the event's five attempts and send the operator
    # a duplicate alert — the exact noise the compare-and-set claim exists to
    # stop.
    it 'leaves a claim a worker is still holding alone' do
      cancelled_row
      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole
      inbox.update_columns(status: StripeEventInbox::PROCESSING, attempts: 1, updated_at: 2.minutes.ago)

      ProcessStripeEventJob.jobs.clear

      report = described_class.new.perform

      expect(report.requeued).to eq(0)
      expect(inbox.reload.status).to eq('processing')
      expect(inbox.attempts).to eq(1)
      expect(inbox.last_error).to be_nil
      expect(ProcessStripeEventJob.jobs).to be_empty
    end

    # D6 (review 8). The sweep read the stale ids and then handed a bare
    # `where(id: ...)` to the writer, whose UPDATE had lost the staleness
    # predicate — so a row a live worker claimed in the gap between the two was
    # released out from under it: two workers on one Stripe event, and a note
    # on the row saying nobody owned it. The staleness is decided by the write
    # now, exactly as it already was on the console's own Retry button.
    it 'does not release a claim taken between reading the stale ids and writing' do
      cancelled_row
      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole
      inbox.update_columns(status: StripeEventInbox::PROCESSING, attempts: 1,
                           updated_at: (StripeEventInbox::STALE_CLAIM_AFTER + 10.minutes).ago)

      # A worker picks the row up in the instant between the two statements.
      allow(described_class).to receive(:release_stale_claims!).and_wrap_original do |original, scope|
        inbox.update_columns(updated_at: Time.current)

        original.call(scope)
      end

      ProcessStripeEventJob.jobs.clear
      described_class.new.perform

      expect(inbox.reload.status).to eq('processing')
      expect(inbox.attempts).to eq(1)
      expect(inbox.last_error).to be_nil
    end

    # The same rule stated on the writer itself, which is where it now lives: a
    # caller may narrow WHICH rows are released, never WHEN one may be.
    it 'never releases a fresh claim, whatever scope the caller hands it' do
      cancelled_row
      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole
      inbox.update_columns(status: StripeEventInbox::PROCESSING, attempts: 1, updated_at: 2.minutes.ago)

      expect(described_class.release_stale_claims!(StripeEventInbox.where(id: inbox.id))).to eq(0)
      expect(described_class.release_stale_claims!(StripeEventInbox.all)).to eq(0)
      expect(inbox.reload.status).to eq('processing')
      expect(inbox.last_error).to be_nil

      inbox.update_columns(updated_at: (StripeEventInbox::STALE_CLAIM_AFTER + 1.minute).ago)

      expect(described_class.release_stale_claims!(StripeEventInbox.where(id: inbox.id))).to eq(1)
      expect(inbox.reload.status).to eq('failed')
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

    # C8 (checkpoint 8). A `failed` row is not idle: writing `failed` is how
    # the job hands the row back BEFORE Sidekiq's own retry chain picks it up
    # again. Re-enqueuing it while that chain still owns it starts a second
    # worker racing for one compare-and-set claim, and the loser burns an
    # attempt out of a budget of five to discover it lost.
    it 'leaves a failed row Sidekiq still owns alone, and takes it once the retry window has passed' do
      cancelled_row
      post_stripe_event('event-customer.subscription.created-trialing')

      inbox = StripeEventInbox.sole
      inbox.update_columns(status: StripeEventInbox::FAILED, attempts: 1, updated_at: 2.minutes.ago)

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      ProcessStripeEventJob.jobs.clear

      expect(described_class.new.perform.requeued).to eq(0)
      expect(ProcessStripeEventJob.jobs).to be_empty
      expect(inbox.reload.status).to eq('failed')

      inbox.update_columns(updated_at: (StripeEventInbox::RETRY_AFTER + 1.minute).ago)

      expect(described_class.new.perform.requeued).to eq(1)
      expect(ProcessStripeEventJob.jobs.map { |job| job['args'].first }).to eq([inbox.id])
    end

    # C5 (checkpoint 8). A subscription DELETED at Stripe — not cancelled,
    # removed — answers 404 to every retrieve. The sweep used to file that as
    # one more transient error and file it again the next night, so the row
    # kept whatever access it last had for ever: an account on the paid plan
    # with nothing paying for it. Only Stripe's explicit `resource_missing`
    # counts; any other failure is still transient (the example below).
    it 'cancels a row whose subscription Stripe no longer has, and hands the account the free plan' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)

      stub_request(:get, subscription_url(subscription_a))
        .with(query: hash_including('expand' => StripeBilling::SUBSCRIPTION_EXPAND))
        .to_return(status: 404,
                   body: { error: { type: 'invalid_request_error', code: 'resource_missing',
                                    message: 'No such subscription' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
      # A subscription really deleted leaves its customer behind, and that is
      # what tells "gone" apart from "wrong key" (review 1, H2).
      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/customers/#{Regexp.escape(customer_a)}})
        .to_return(status: 200, body: { id: customer_a, object: 'customer' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(report.errors).to be_empty
      expect(report.vanished.sole).to include(account_id: account.id, subscription: subscription_a,
                                              was: 'active', now: 'cancelled')
      expect(row.reload.access_state).to eq('cancelled')
      expect(account.reload.purged_at).to be_nil
      expect(alerts.sole[:body]).to include(subscription_a)

      expect_free_plan
    end

    # A3 (checkpoint 8). The automatic refund of a NEWER duplicate rests on
    # one claim: every cycle it collected duplicated one the survivor was
    # already billing. A survivor whose collection was PAUSED breaks that
    # claim — while it was paused it billed nothing, so what the newer one
    # took may be the only money the customer ever paid for the service they
    # had. The duplicate is still cancelled; the refund becomes a person's
    # decision, and the sweep names it under "needs manual review".
    context 'when the survivor has a paused-collection history' do
      let!(:row) do
        create(:account_subscription, account:, access_state: 'active', status: 'active',
                                      stripe_status: 'active', stripe_customer_id: customer_a,
                                      stripe_subscription_id: subscription_a, quantity: 1)
      end

      before do
        stub_subscription_list(customer_a, { subscription_a => 'active', subscription_b => 'active' })
        stub_invoice_list(subscription_b, [paid_invoice(subscription_b, amount: 3000)])
        stub_duplicate(subscription_b, 'subscription-active')
      end

      # No refund stub anywhere in this example: a refund attempt would reach
      # an unstubbed Stripe request and fail the example outright.
      def expect_manual_review(report)
        expect(report.duplicates.sole).to include(account_id: account.id, cancelled: subscription_b,
                                                  refunded: nil)
        expect(report.manual_refunds.sole[:cancelled]).to eq(subscription_b)
        expect(row.reload.stripe_subscription_id).to eq(subscription_a)
      end

      it 'routes the duplicate to manual review when the survivor is paused right now' do
        stub_subscription(subscription_a, 'subscription-active', { 'pause_collection' => { 'behavior' => 'void' } })
        cancel_call = stub_cancel(subscription_b, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)

        allow(OperatorAlert).to receive(:deliver).and_return(true)
        allow(ErrorReport).to receive(:warning)

        report = described_class.new.perform

        expect(cancel_call).to have_been_requested
        expect_manual_review(report)
        expect(report.manual_refunds.sole[:note]).to include('paused-collection history')
      end

      # And the same when the pause has already been LIFTED: the subscription
      # no longer says anything about itself, so the events we stored at the
      # time are what remember it.
      #
      # Which events those are is the whole of Codex H4. Stripe does NOT emit
      # `customer.subscription.paused` for a paused COLLECTION — that event is
      # about a paused subscription STATUS. Setting and clearing
      # `pause_collection` both arrive as an ordinary
      # `customer.subscription.updated`: on the object when set, and named in
      # `previous_attributes` when cleared.
      def store_event!(id, type, object_extra: {}, previous: nil)
        data = { object: { id: subscription_a, object: 'subscription', status: 'active' }.merge(object_extra) }
        data[:previous_attributes] = previous if previous

        StripeEventInbox.create!(stripe_event_id: id, event_type: type, status: 'processed',
                                 payload: { id:, type:, data: }.to_json)
      end

      it 'routes it to manual review when an update SET the collection pause' do
        store_event!('evt_paused', 'customer.subscription.updated',
                     object_extra: { pause_collection: { behavior: 'void', resumes_at: nil } },
                     previous: { pause_collection: nil })

        stub_subscription(subscription_a, 'subscription-active')
        cancel_call = stub_cancel(subscription_b, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)

        allow(OperatorAlert).to receive(:deliver).and_return(true)
        allow(ErrorReport).to receive(:warning)

        report = described_class.new.perform

        expect(cancel_call).to have_been_requested
        expect_manual_review(report)
      end

      it 'routes it to manual review when an update CLEARED the collection pause' do
        store_event!('evt_resumed', 'customer.subscription.updated',
                     previous: { pause_collection: { behavior: 'void', resumes_at: nil } })

        stub_subscription(subscription_a, 'subscription-active')
        cancel_call = stub_cancel(subscription_b, marker: StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER)

        allow(OperatorAlert).to receive(:deliver).and_return(true)
        allow(ErrorReport).to receive(:warning)

        report = described_class.new.perform

        expect(cancel_call).to have_been_requested
        expect_manual_review(report)
      end

      # And the other half of reading the right field: an ordinary update that
      # has nothing to do with collection is not a pause. Without this, "look
      # at customer.subscription.updated" would send every duplicate on every
      # busy account to manual review and no refund would ever go out.
      it 'is not fooled by an ordinary update on the survivor' do
        store_event!('evt_quantity', 'customer.subscription.updated', previous: { quantity: 1 })

        stub_subscription(subscription_a, 'subscription-active')
        stub_cancel(subscription_b, marker: StripeBilling::DUPLICATE_CANCEL_MARKER,
                                    invoice: paid_invoice(subscription_b, amount: 3000))
        refund_call = stub_refund("pi_#{subscription_b}", amount: 3000)

        allow(OperatorAlert).to receive(:deliver).and_return(true)
        allow(ErrorReport).to receive(:warning)

        report = described_class.new.perform

        expect(refund_call).to have_been_requested
        expect(report.manual_refunds).to be_empty
      end

      # The control: the very same duplicate, with a survivor that was never
      # paused, IS refunded automatically. Without this the two examples above
      # would pass just as well if the app had stopped refunding altogether.
      it 'still refunds the newer duplicate automatically when the survivor was never paused' do
        stub_subscription(subscription_a, 'subscription-active')
        stub_cancel(subscription_b, marker: StripeBilling::DUPLICATE_CANCEL_MARKER,
                                    invoice: paid_invoice(subscription_b, amount: 3000))
        refund_call = stub_refund("pi_#{subscription_b}", amount: 3000)

        allow(OperatorAlert).to receive(:deliver).and_return(true)
        allow(ErrorReport).to receive(:warning)

        report = described_class.new.perform

        expect(refund_call).to have_been_requested
        expect(report.manual_refunds).to be_empty
        expect(report.duplicates.sole[:refunded]).to eq('$30.00')
      end
    end

    # Review 1 H2 / Codex H1. `resource_missing` is also what a key pointed at
    # the WRONG Stripe account answers for every id we hold — so before
    # anything is downgraded the customer is fetched, and a customer that is
    # missing too stops the sweep instead of moving the paying customer base
    # to the free plan.
    context 'when Stripe cannot find a subscription' do
      let(:missing_body) do
        { error: { type: 'invalid_request_error', code: 'resource_missing',
                   message: 'No such subscription' } }.to_json
      end

      def missing_response
        { status: 404, body: missing_body, headers: { 'Content-Type' => 'application/json' } }
      end

      def stub_missing_subscription(id, &)
        stub = stub_request(:get, subscription_url(id))
               .with(query: hash_including('expand' => StripeBilling::SUBSCRIPTION_EXPAND))

        return stub.to_return(&) if block_given?

        stub.to_return(**missing_response)
      end

      def customer_response(id, status)
        { status:, body: status == 200 ? { id:, object: 'customer' }.to_json : missing_body,
          headers: { 'Content-Type' => 'application/json' } }
      end

      def stub_customer(id, status: 200, &)
        stub = stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/customers/#{Regexp.escape(id)}})

        return stub.to_return(&) if block_given?

        stub.to_return(**customer_response(id, status))
      end

      it 'downgrades nothing and stops when the key cannot find the customer either' do
        row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                            stripe_customer_id: customer_a,
                                            stripe_subscription_id: subscription_a, quantity: 3)

        stub_missing_subscription(subscription_a)
        stub_customer(customer_a, status: 404)

        alerts = []
        allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
        allow(ErrorReport).to receive(:warning)
        allow(ErrorReport).to receive(:error)

        report = described_class.new.perform

        expect(report.key_mismatch).to include(customer_a)
        expect(report.vanished).to be_empty
        expect(row.reload.access_state).to eq('active')
        expect(alerts.sole[:body]).to include('STOPPED')
        expect(alerts.sole[:body]).to include('STRIPE_SECRET_KEY')

        expect_paid_access
      end

      it 'settles only a few in one run and leaves the rest for a person' do
        stub_const("#{described_class}::VANISHED_LIMIT", 2)

        rows = Array.new(3) do |i|
          create(:account_subscription, account: create(:account), access_state: 'active', status: 'active',
                                        stripe_customer_id: "cus_missing_#{i}",
                                        stripe_subscription_id: "sub_missing_#{i}", quantity: 1)
        end

        rows.each_with_index do |_row, i|
          stub_missing_subscription("sub_missing_#{i}")
          stub_customer("cus_missing_#{i}")
        end

        allow(OperatorAlert).to receive(:deliver).and_return(true)
        allow(ErrorReport).to receive(:warning)

        report = described_class.new.perform

        expect(report.vanished.size).to eq(2)
        expect(report.vanished_skipped.sole).to include(account_id: rows.last.account_id,
                                                        subscription: 'sub_missing_2')
        expect(report.vanished_skipped.sole[:reason]).to include('more than 2')
        expect(rows.first.reload.access_state).to eq('cancelled')
        expect(rows.last.reload.access_state).to eq('active')
      end

      # Review 1 loop 2. A row that names no customer can prove nothing either
      # way. Treating it as "wrong key" stopped the whole sweep, so one legacy
      # row would have starved every account behind it, every night, for ever.
      it 'skips a row that names no customer and keeps sweeping' do
        orphan = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                               stripe_customer_id: nil,
                                               stripe_subscription_id: 'sub_no_customer', quantity: 1)
        later = create(:account_subscription, account: create(:account), access_state: 'active', status: 'active',
                                              stripe_customer_id: customer_b,
                                              stripe_subscription_id: subscription_b, quantity: 2)

        stub_missing_subscription('sub_no_customer')
        stub_subscription(subscription_b, 'subscription-canceled')

        allow(OperatorAlert).to receive(:deliver).and_return(true)
        allow(ErrorReport).to receive(:warning)

        report = described_class.new.perform

        expect(report.key_mismatch).to be_nil
        expect(report.vanished).to be_empty
        expect(report.vanished_skipped.sole).to include(account_id: account.id, subscription: 'sub_no_customer')
        expect(report.vanished_skipped.sole[:reason]).to include('names no Stripe customer')
        expect(orphan.reload.access_state).to eq('active')
        # The sweep carried on: the row AFTER it was still reconciled.
        expect(later.reload.access_state).to eq('cancelled')
      end

      # The 404 is about ONE subscription id. If a webhook repoints the row
      # while the sweep is asking, cancelling whatever the row holds by then
      # would downgrade a live subscription nobody said anything about.
      it 'leaves the row alone when it has moved on to another subscription in the meantime' do
        row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                            stripe_customer_id: customer_a,
                                            stripe_subscription_id: subscription_a, quantity: 1)

        stub_missing_subscription(subscription_a)
        # The swap lands between the 404 and the row lock — which is where the
        # real race is, a webhook adopting another subscription while the
        # sweep is asking Stripe about this one.
        stub_customer(customer_a) do
          row.update_columns(stripe_subscription_id: subscription_b)

          customer_response(customer_a, 200)
        end

        allow(OperatorAlert).to receive(:deliver).and_return(true)
        allow(ErrorReport).to receive(:warning)

        report = described_class.new.perform

        expect(report.vanished).to be_empty
        expect(report.vanished_skipped.sole[:reason]).to include('different subscription')
        expect(row.reload.access_state).to eq('active')
        expect(row.stripe_subscription_id).to eq(subscription_b)
      end
    end

    # C10 (checkpoint 8). The sweep is serial and asks Stripe at least twice
    # per row, and nothing bounded it: at enough accounts it would still be
    # running when the next night's copy started. It now stops on a
    # wall-clock budget, says where it stopped, and carries on from there —
    # so a platform too big for one night is swept a slice at a time rather
    # than having its first N accounts swept every night and the rest never.
    it 'stops when its budget is gone, says so, and the next sweep carries on after that row' do
      stub_const("#{described_class}::SWEEP_BUDGET", 0)

      first = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                            stripe_customer_id: customer_a,
                                            stripe_subscription_id: subscription_a, quantity: 1)
      second = create(:account_subscription, account: create(:account), access_state: 'active', status: 'active',
                                             stripe_customer_id: customer_b,
                                             stripe_subscription_id: subscription_b, quantity: 2)

      stub_subscription(subscription_a, 'subscription-canceled')
      stub_subscription(subscription_b, 'subscription-canceled')

      alerts = []
      allow(OperatorAlert).to receive(:deliver) { |args| alerts << args }
      allow(ErrorReport).to receive(:warning)

      report = described_class.new.perform

      expect(report.rows).to eq(1)
      expect(report.stopped_after).to eq(first.id)
      expect(StripeReconciliationState.cursor).to eq(first.id)
      expect(first.reload.access_state).to eq('cancelled')
      expect(second.reload.access_state).to eq('active')
      expect(alerts.sole[:body]).to include('Budget exhausted after 1 row(s)')

      second_report = described_class.new.perform

      expect(second_report.rows).to eq(1)
      expect(second_report.repaired.sole).to include(account_id: second.account_id)
      expect(second.reload.access_state).to eq('cancelled')
    end

    # And the report itself outlives the run, for the operator console's
    # billing tab to read (StripeReconciliationState).
    it 'keeps the last report where the console can read it' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 1)

      stub_subscription(subscription_a, 'subscription-canceled')
      allow(OperatorAlert).to receive(:deliver).and_return(true)

      described_class.new.perform

      kept = StripeReconciliationState.last_report

      expect(kept['ran_at']).to be_present
      expect(kept['rows']).to eq(1)
      expect(kept['repaired'].sole).to include('account_id' => row.account_id, 'now' => 'cancelled')
    ensure
      StripeReconciliationState.delete(StripeReconciliationState::REPORT_KEY)
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

    # D43, prospective counters: an operator's revoke ends paid access exactly
    # as a Stripe cancellation does, so it has to leave the same trail — the
    # moment the paid plan stopped and a snapshot of the send counter taken
    # there. Without it the account would be measured against the documents it
    # completed while it was paying and would read "3 of 5" on a free plan it
    # has only just landed on, while a customer Stripe cancelled reads 0 of 5.
    #
    # Driven through the real doors: real sends, a real signer PUT for each
    # completion. No metering row is written by hand.
    it 'starts a fresh free month at the revoke: 0 of 5 completions, 0 of 15 sends', sidekiq: :inline do
      platform_certificate!
      create(:account_subscription, account: parent, access_state: 'active', status: 'manual', quantity: 2)

      admin = create(:user, account: parent)
      template = create(:template, account: parent, author: admin, only_field_types: %w[text])

      # A clear minute before the revoke: this is about which SIDE of the
      # cancellation the paid month's work falls on, and `ended_at` is stamped
      # to the whole second.
      travel_to(1.minute.ago) do
        3.times do
          submission = Submissions.create_from_emails(template:, user: admin,
                                                      emails: "signer-#{SecureRandom.hex(4)}@example.com",
                                                      source: :invite, mark_as_sent: true).sole

          complete!(submission.submitters.first)
        end
      end

      expect(Quotas.completions_this_month(parent)).to eq(3)
      expect(Quotas.sends_this_month(parent)).to eq(3)

      run_rake_task('plans:revoke', parent.id.to_s)

      parent.reload

      expect(Plans.key_for(parent)).to eq(Plans::FREE)
      expect(parent.account_subscription.ended_at).to be_present
      expect(Quotas.completions_this_month(parent)).to eq(0)
      expect(Quotas.sends_this_month(parent)).to eq(0)
      # The durable counter is append-only and was NOT rewritten — only the
      # mark saying where the free month starts is new, so "deleting a
      # document never gives a send back" is exactly as true as before.
      expect(AccountCounters.value(parent.id, 'submissions_created')).to eq(3)
      expect(AccountCounters.value(parent.id, Quotas::DOWNGRADE_SENDS_OFFSET_KEY)).to eq(3)
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

    # --- a row the CHILD owns ------------------------------------------------
    #
    # A customer account that bought for itself and was linked under a parent
    # afterwards keeps a row of its own — and nothing in the app reads it any
    # more: the plan, the billing page and the operator all look at the
    # PARENT's row. Asking only "is my BILLING account a customer?" answered
    # yes for such a row, because the parent is one, so the webhook processor
    # and the nightly sweep went on applying, cancelling and refunding
    # against a row the rest of the app ignores. Every door below refuses it
    # — and because it carries Stripe ids, every refusal is reported: there
    # is a subscription at Stripe that nothing here is managing.

    it 'applies no subscription event to a row the child owns' do
      row = create(:account_subscription, account: child, access_state: 'cancelled', status: 'none',
                                          stripe_customer_id: customer_a)

      stub_subscription(subscription_a, 'subscription-trialing')
      allow(ErrorReport).to receive(:warning)

      post_stripe_event('event-customer.subscription.created-trialing')
      drain_stripe_jobs

      expect(row.reload).to have_attributes(access_state: 'cancelled', stripe_subscription_id: nil)
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::NON_CUSTOMER_ACCOUNT)
      expect(ErrorReport).to have_received(:warning)
        .with(/unmanaged Stripe subscription/, hash_including(account_id: child.id))
    end

    it 'applies no invoice event to a row the child owns, and starts no dunning clock on it' do
      row = create(:account_subscription, account: child, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_b,
                                          stripe_subscription_id: subscription_b, quantity: 2)

      stub_subscription(subscription_b, 'subscription-past_due')
      allow(ErrorReport).to receive(:warning)

      post_stripe_event('event-invoice.payment_failed')
      drain_stripe_jobs

      expect(row.reload).to have_attributes(access_state: 'active', stripe_status: 'active', past_due_since: nil)
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      expect(StripeEventInbox.sole)
        .to have_attributes(status: 'ignored', last_error: ProcessStripeEventJob::NON_CUSTOMER_ACCOUNT)
      expect(ErrorReport).to have_received(:warning)
        .with(/unmanaged Stripe subscription #{subscription_b}/, hash_including(account_id: child.id))
    end

    it 'never repairs or cancels for a row the child owns in the nightly sweep' do
      row = create(:account_subscription, account: child, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_customer_id: customer_a,
                                          stripe_subscription_id: subscription_a, quantity: 3)

      stub_subscription(subscription_a, 'subscription-canceled')
      stub_subscription_list(customer_a, { subscription_a => 'active', subscription_b => 'active' })
      stub_duplicate(subscription_b, 'subscription-active')
      stub_cancel(subscription_b)
      allow(ErrorReport).to receive(:warning)

      report = StripeReconciliationJob.new.perform

      expect(row.reload.access_state).to eq('active')
      expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      expect(a_request(:delete, %r{api\.stripe\.com/v1/subscriptions/})).not_to have_been_made
      expect(report.repaired).to be_empty
      expect(report.duplicates).to be_empty
      expect(ErrorReport).to have_received(:warning)
        .with(/unmanaged Stripe subscription #{subscription_a}/, hash_including(account_id: child.id))
    end

    # The one predicate both callers ask, over every shape of row at once:
    # the ordinary customer paying for itself is managed, and a linked child,
    # an internal account and an operator account are not. Only a refused row
    # with money behind it is reported.
    it 'manages a row its own customer pays for, and refuses every other kind' do
      allow(ErrorReport).to receive(:warning)

      own = create(:account_subscription, account:, stripe_customer_id: customer_a)
      child_owned = create(:account_subscription, account: child, stripe_customer_id: customer_b)
      internal = create(:account_subscription, account: create(:account, :internal))
      operator = create(:account_subscription, account: create(:account, :operator))

      expect(own.billing_customer?).to be(true)
      expect(child_owned.billing_customer?).to be(false)
      expect(internal.billing_customer?).to be(false)
      expect(operator.billing_customer?).to be(false)
      expect(ErrorReport).to have_received(:warning)
        .with(/unmanaged Stripe subscription/, hash_including(account_id: child.id)).once
    end
  end

  describe StripeBilling::ConfigGuard do
    around do |example|
      original = Rails.env

      example.run
    ensure
      Rails.env = original
    end

    # Four ways to fail the same gate, one example each. The baseline
    # environment is re-seeded per example by spec/support/stripe_test_account.rb,
    # so a row that names nothing is starting from the good test configuration
    # — which is what makes "a test key in production" a row with no setup.
    #
    # A key that is neither sk_live_ nor sk_test_ has no mode at all, and
    # "not obviously a test key" was enough to boot production on it.
    [
      ['refuses to boot production with a key missing',
       { 'STRIPE_PORTAL_CONFIGURATION_ID' => nil },
       /STRIPE_PORTAL_CONFIGURATION_ID is not set/],
      ['refuses to boot production with a value that is not the thing it names',
       { 'STRIPE_WEBHOOK_SECRET' => 'sk_test_oops', 'STRIPE_SECRET_KEY' => 'sk_live_realkey' },
       /STRIPE_WEBHOOK_SECRET does not look like a Stripe value.*whsec_/],
      ['refuses to run production against a test key',
       {},
       /STRIPE_SECRET_KEY must be a live key.*in production/],
      ['refuses to boot production on a key that is neither live nor test',
       { 'STRIPE_SECRET_KEY' => 'sk_invalid' },
       /STRIPE_SECRET_KEY must be a live key.*in production/]
    ].each do |description, env, message|
      it description do
        env.each { |name, value| ENV[name] = value }
        Rails.env = 'production'

        expect { described_class.check! }.to raise_error(message)
      end
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

    # The whole cancel walk and the customer-details list are part of the
    # manifest, so the stub carries them and an example that is about one of
    # them overrides only that one (X7a).
    def stub_portal(subscription_update_enabled: false, cancel: {}, customer_update: {})
      body = { id: 'bpc_test', object: 'billing_portal.configuration', active: true,
               features: { invoice_history: { enabled: true }, payment_method_update: { enabled: true },
                           subscription_cancel: { enabled: true, mode: 'at_period_end',
                                                  proration_behavior: 'none' }.merge(cancel),
                           customer_update: { enabled: true,
                                              allowed_updates: %w[email address name] }.merge(customer_update),
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

    # X7(a): the cancel BUTTON being on is not the same as the cancellation
    # behaving the way the product promises. A portal switched to cancel
    # immediately takes away the month the customer has already paid for; one
    # that prorates hands back money the app never accounts for (D43 says a
    # reduction is never refunded); and dropping `address` from the details a
    # customer may edit leaves them unable to fix an invoice Checkout itself
    # collected an address for. All three are one hand-edit away in the
    # dashboard, so all three are asserted against the manifest.
    it 'fails when the portal cancels immediately, prorates it, or stops a customer fixing their address' do
      stub_price
      stub_portal(cancel: { mode: 'immediately', proration_behavior: 'create_prorations' },
                  customer_update: { allowed_updates: %w[email name] })
      stub_endpoints(['https://esign.example.com/stripe/webhooks'])

      rows = StripeBilling::Checks.rows

      expect(StripeBilling::Checks.failed?(rows)).to be(true)
      expect(rows.find { |row| row[:name] == 'portal cancel at period end' })
        .to include(result: 'FAIL', detail: 'mode=immediately (expected at_period_end)')
      expect(rows.find { |row| row[:name] == 'portal cancel proration off' })
        .to include(result: 'FAIL', detail: 'proration_behavior=create_prorations (expected none)')
      expect(rows.find { |row| row[:name] == 'portal customer_update matches the manifest' })
        .to include(result: 'FAIL', detail: 'allowed_updates=email, name (expected email, address, name)')
      # The button itself is still on: this is about what it does.
      expect(rows.find { |row| row[:name] == 'portal subscription_cancel on' }).to include(result: 'PASS')
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
  include_context 'with a Stripe test account'

  self.use_transactional_tests = false

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
