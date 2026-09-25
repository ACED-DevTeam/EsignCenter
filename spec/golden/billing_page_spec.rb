# frozen_string_literal: true

# The billing page (/settings/billing) and the two doors to Stripe behind it.
#
# What this file protects: the page tells the truth in every subscription
# state; the price, the quantity and the trial are decided by the server and
# never by a request parameter; the whole surface is invisible (404) while the
# BILLING_ENABLED switch is off, to an internal or operator account, and to a
# user who does not administer the account; a child account sees its parent's
# billing and no buttons; and a Stripe outage is a sentence, not a 500.
#
# Stripe itself is stubbed with WebMock — no HTTP leaves the suite — and the
# subscription that comes back from the Checkout return is a real CLI capture
# (spec/fixtures/stripe/subscription-trialing.json).
RSpec.describe 'Billing page', type: :request do # rubocop:disable RSpec/MultipleDescribes
  let(:price_id) { 'price_1UAt8N4rEeOqtLcX1amJxYdZ' }
  let(:portal_configuration_id) { 'bpc_test' }
  let(:checkout_url) { 'https://checkout.stripe.com/c/pay/cs_test_fixture' }
  let(:portal_url) { 'https://billing.stripe.com/p/session/bps_test_fixture' }
  let!(:account) { create(:account) }
  let(:admins) { {} }

  stash_env(*StripeBilling::CONFIG_KEYS.keys, 'BILLING_ENABLED')

  before do
    ENV['STRIPE_SECRET_KEY'] = 'sk_test_fake'
    ENV['STRIPE_PUBLISHABLE_KEY'] = 'pk_test_fake'
    ENV['STRIPE_WEBHOOK_SECRET'] = 'whsec_testsecret'
    ENV['STRIPE_PRICE_ID'] = price_id
    ENV['STRIPE_PORTAL_CONFIGURATION_ID'] = portal_configuration_id
    ENV['BILLING_ENABLED'] = 'true'

    stub_subscription_list
    stub_customer_search([])
    # Every duplicate the app cancels is asked what it ever collected;
    # unless an example says otherwise, the answer is "nothing".
    stub_invoice_list
  end

  def admin_for(record)
    admins[record.id] ||= create(:user, account: record)
  end

  # A fresh integration session is the only reliable actor switch (see
  # spec/golden/gating_spec.rb).
  def act_as(user)
    sign_out(:user)
    reset!
    sign_in(user)
  end

  def page(path = '/settings/billing')
    get path

    expect(response).to have_http_status(:ok)

    Nokogiri::HTML(response.body)
  end

  def stripe_json(body)
    { status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  def stub_customer_create(id: 'cus_created')
    stub_request(:post, 'https://api.stripe.com/v1/customers')
      .to_return(**stripe_json(id:, object: 'customer'))
  end

  # Stripe is asked for a customer already tagged with this account before
  # one is created; unless an example is about that, there is none. The
  # query is asserted — on the NAMESPACED tag key, spelled out here rather
  # than read from the constant — so searching for the wrong account, or
  # under a key another product on the same Stripe account could also be
  # using, could not pass (review 7, A1).
  def stub_customer_search(*found, record: account)
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/customers/search})
      .with(query: hash_including('query' => "metadata['esigncenter_account_id']:'#{record.id}'"))
      .to_return(*found.map do |ids|
        stripe_json(object: 'search_result', data: ids.map { |id| { id:, object: 'customer' } })
      end)
  end

  def stub_checkout_create
    stub_request(:post, 'https://api.stripe.com/v1/checkout/sessions')
      .to_return(**stripe_json(id: 'cs_test_fixture', object: 'checkout.session', url: checkout_url))
  end

  # A subscription as Stripe's LIST returns it: ours when it carries an item
  # on our price, a stranger's when it sits on some other price.
  def listed_subscription(id, status, price: price_id, created: 1_788_411_000)
    { id:, object: 'subscription', status:, created:, metadata: {},
      items: { object: 'list', data: [{ id: "si_#{id}", object: 'subscription_item', price:, quantity: 1 }] } }
  end

  # The app asks Stripe what the customer already has before selling
  # anything; unless an example is about that, the answer is "nothing". An
  # example that IS about it names the customer, so listing somebody else's
  # subscriptions could not pass. `entries` are ids → statuses (on our
  # price) or ready-made list rows.
  def stub_subscription_list(customer = nil, entries = {}, has_more: false, starting_after: nil)
    data = entries.map { |id, status| status.is_a?(Hash) ? status : listed_subscription(id, status) }
    stub = stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions\?})

    if customer
      query = { 'customer' => customer, 'status' => 'all', 'limit' => '100' }
      query['starting_after'] = starting_after if starting_after
      stub = stub.with(query: hash_including(query))
    end

    stub.to_return(**stripe_json(object: 'list', data:, has_more:))
  end

  # On the exact subscription id, and on the expansion the app asks for.
  def stub_subscription_retrieve(id, subscription, expand: StripeBilling::SUBSCRIPTION_EXPAND)
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{id}})
      .with(query: hash_including('expand' => expand))
      .to_return(**stripe_json(subscription))
  end

  # A duplicate is fetched, and cancelled, with its latest invoice and that
  # invoice's payments: the app has to know what it already charged.
  def stub_duplicate(id, subscription, invoice: unpaid_invoice(id))
    stub_subscription_retrieve(id, subscription.merge('id' => id, 'latest_invoice' => invoice),
                               expand: StripeBilling::Linker::DUPLICATE_EXPAND)
  end

  # The marker's authority is the metadata write that comes first — only a
  # secret key can make it — and the comment beside it is what a person reads.
  def stub_cancel(id, subscription, invoice: unpaid_invoice(id))
    stub_request(:post, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{id}})
      .with(body: hash_including('metadata' => hash_including(
        StripeBilling::DUPLICATE_CANCEL_METADATA_KEY => StripeBilling::DUPLICATE_CANCEL_METADATA
      )),
            headers: { 'Idempotency-Key' => "mark-duplicate-#{id}" })
      .to_return(**stripe_json({ 'id' => id, 'object' => 'subscription' }))

    stub_request(:delete, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{id}})
      .with(query: hash_including('expand' => StripeBilling::Linker::DUPLICATE_EXPAND,
                                  'cancellation_details' => { 'comment' => StripeBilling::DUPLICATE_CANCEL_MARKER }))
      .to_return(**stripe_json(subscription.merge('id' => id, 'status' => 'canceled', 'latest_invoice' => invoice)))
  end

  # What the app is told a subscription ever collected. A refund is made per
  # paid invoice, so an example that expects one names its invoices here.
  def stub_invoice_list(subscription_id = nil, invoices = [], has_more: false)
    query = { 'status' => 'paid' }
    query['subscription'] = subscription_id if subscription_id

    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/invoices})
      .with(query: hash_including(query))
      .to_return(**stripe_json(object: 'list', data: invoices, has_more:))
  end

  def unpaid_invoice(subscription_id)
    { id: "in_trial_#{subscription_id}", object: 'invoice', amount_paid: 0, currency: 'usd',
      payments: { object: 'list', data: [] } }
  end

  # An invoice the duplicate collected. `created` is only used to pick the
  # latest one for an operator note; what is refunded is decided per
  # PaymentIntent, not per invoice.
  def paid_invoice(subscription_id, amount:, created: 1_788_411_000)
    { id: "in_paid_#{subscription_id}", object: 'invoice', amount_paid: amount, currency: 'usd', created:,
      payments: { object: 'list',
                  data: [{ object: 'invoice_payment', status: 'paid',
                           payment: { type: 'payment_intent', payment_intent: "pi_#{subscription_id}" } }] } }
  end

  # What the payment took and how much has already come back, read off the
  # charge behind the PaymentIntent.
  def stub_payment_intent(payment_intent, amount:, refunded: 0)
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/payment_intents/#{Regexp.escape(payment_intent)}})
      .to_return(**stripe_json(id: payment_intent, object: 'payment_intent',
                               latest_charge: { id: "ch_#{payment_intent}", object: 'charge', amount:,
                                                amount_captured: amount, amount_refunded: refunded,
                                                currency: 'usd' }))
  end

  # The row Checkout leaves behind before the customer ever reaches Stripe's
  # page: linked to the customer, not yet paid for anything.
  def checkout_row!(customer:, record: account)
    create(:account_subscription, account: record, access_state: 'cancelled', status: 'none',
                                  stripe_customer_id: customer)
  end

  def stub_portal_create
    stub_request(:post, 'https://api.stripe.com/v1/billing_portal/sessions')
      .to_return(**stripe_json(id: 'bps_test_fixture', object: 'billing_portal.session', url: portal_url))
  end

  # The real capture, tagged the way this account's own Checkout would tag
  # it (the capture was made for a placeholder account id).
  def trialing_subscription
    JSON.parse(Rails.root.join('spec/fixtures/stripe/subscription-trialing.json').read)
        .merge('metadata' => { 'esigncenter_account_id' => account.id.to_s })
  end

  # On the exact session id, and on the expansion the app asks for: the
  # subscription comes back inline or not at all.
  def stub_checkout_retrieve(session_id, reference:, subscription: trialing_subscription,
                             status: 'complete', mode: 'subscription', customer: nil)
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/checkout/sessions/#{session_id}})
      .with(query: hash_including('expand' => ['subscription']))
      .to_return(**stripe_json(id: session_id, object: 'checkout.session', mode:, status:,
                               client_reference_id: reference,
                               customer: customer || subscription['customer'], subscription:))
  end

  # The form body Stripe actually received, as a nested hash.
  def posted(url)
    body = nil
    expect(WebMock).to have_requested(:post, url).with { |request| body = request.body } # rubocop:disable Lint/AmbiguousBlockAssociation
    Rack::Utils.parse_nested_query(body)
  end

  def stripe_trialing!(record, seats: 1, trial_used: true)
    create(:account_subscription, account: record, access_state: 'trialing', status: 'trialing',
                                  stripe_status: 'trialing', quantity: seats,
                                  stripe_customer_id: "cus_#{record.id}",
                                  stripe_subscription_id: "sub_#{record.id}",
                                  trial_end: 12.days.from_now,
                                  current_period_end: 12.days.from_now,
                                  trial_used_at: (Time.current if trial_used))
  end

  describe 'who may see it at all' do
    it '404s on every action while BILLING_ENABLED is off' do
      ENV['BILLING_ENABLED'] = 'false'
      act_as(admin_for(account))

      get '/settings/billing'
      expect(response).to have_http_status(:not_found)

      post '/settings/billing/checkout'
      expect(response).to have_http_status(:not_found)

      post '/settings/billing/portal'
      expect(response).to have_http_status(:not_found)

      get '/settings/billing/return', params: { cancelled: 1 }
      expect(response).to have_http_status(:not_found)

      expect(AccountSubscription.count).to eq(0)
    end

    it '404s for an internal account and for an operator account' do
      [create(:account, :internal), create(:account, :operator)].each do |platform_account|
        act_as(admin_for(platform_account))

        get '/settings/billing'
        expect(response).to have_http_status(:not_found)

        post '/settings/billing/checkout'
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'refuses a user who does not administer the account' do
      act_as(create(:user, :editor, account:))

      get '/settings/billing'
      expect(response).to redirect_to(root_path)

      post '/settings/billing/checkout'
      expect(response).to redirect_to(root_path)
      expect(AccountSubscription.count).to eq(0)
    end
  end

  describe 'a free customer account' do
    before { act_as(admin_for(account)) }

    it 'shows both plans, the free limits from the quota engine and the trial button' do
      doc = page

      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('free')
      free_card = doc.at('[data-billing-card="free"]')
      expect(free_card.text).to include(I18n.t('billing_free_limit_completions', count: 5))
      expect(free_card.text).to include(I18n.t('billing_free_limit_sends', count: 15))
      expect(free_card.text).to include(I18n.t('billing_free_limit_seats', count: 1))
      expect(free_card.text).to include('Agreement storage')
      expect(free_card.text).not_to match(/\b\d+\s*GB\b/)

      paid_card = doc.at('[data-billing-card="paid"]')
      price_line = I18n.t('billing_paid_plan_price', price: StripeBilling::PRICE_PER_SEAT_USD,
                                                     trial_days: StripeBilling::TRIAL_PERIOD_DAYS)
      expect(paid_card.text).to include(price_line)
      # The price and trial are the constants billing applies, never typed into the copy.
      expect(price_line).to start_with("$#{StripeBilling::PRICE_PER_SEAT_USD} per user per month")
      expect(price_line).to include("#{StripeBilling::TRIAL_PERIOD_DAYS}-day free trial")
      expect(paid_card.text).to include(I18n.t('billing_benefit_api'))
      expect(paid_card.text).to include(I18n.t('billing_seats_billed', count: 1))
      expect(paid_card.at('[data-billing-checkout-button]').text.strip)
        .to eq("Start #{StripeBilling::TRIAL_PERIOD_DAYS}-day free trial")
      expect(paid_card.text).to include(I18n.t('billing_trial_charge_note'))
      expect(doc.at('[data-billing-trial-used]')).to be_nil
      # Nothing to manage yet.
      expect(doc.at('[data-billing-portal-button]')).to be_nil
      expect(doc.at('[data-billing-usage-link]')['href']).to eq('/settings/usage')
    end

    it 'creates the Stripe customer and a subscription-mode Checkout session with the server\'s own numbers' do
      create(:user, account:) # two seats in the account
      stub_customer_create
      stub_checkout_create

      post '/settings/billing/checkout'

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(checkout_url)

      customer = posted('https://api.stripe.com/v1/customers')
      expect(customer.dig('metadata', 'esigncenter_account_id')).to eq(account.id.to_s)
      expect(customer['email']).to eq(admin_for(account).email)

      session = posted('https://api.stripe.com/v1/checkout/sessions')
      expect(session['mode']).to eq('subscription')
      expect(session['client_reference_id']).to eq(account.id.to_s)
      expect(session.dig('line_items', '0', 'price')).to eq(price_id)
      expect(session.dig('line_items', '0', 'quantity')).to eq('2')
      expect(session.dig('subscription_data', 'trial_period_days')).to eq('14')
      expect(session.dig('subscription_data', 'trial_settings', 'end_behavior',
                         'missing_payment_method')).to eq('cancel')
      expect(session.dig('subscription_data', 'metadata', 'esigncenter_account_id')).to eq(account.id.to_s)
      expect(session['payment_method_collection']).to eq('always')
      expect(session['success_url']).to end_with('/settings/billing/return?session_id={CHECKOUT_SESSION_ID}')

      expect(account.reload.account_subscription.stripe_customer_id).to eq('cus_created')
      expect(account.account_subscription.access_state).to eq('cancelled')
    end

    it 'ignores a price, quantity or trial posted by the client' do
      stub_customer_create
      stub_checkout_create

      post '/settings/billing/checkout', params: { price: 'price_attacker', quantity: 500,
                                                   trial_period_days: 3650 }

      session = posted('https://api.stripe.com/v1/checkout/sessions')
      expect(session.dig('line_items', '0', 'price')).to eq(price_id)
      expect(session.dig('line_items', '0', 'quantity')).to eq('1')
      expect(session.dig('subscription_data', 'trial_period_days')).to eq('14')
    end

    # Our own row is not the only witness to a purchase: a Checkout completed
    # in a tab we never heard back from left a live subscription at Stripe,
    # and selling a second one would charge the customer twice.
    it 'refuses to sell a second subscription to a customer Stripe says already has one' do
      checkout_row!(customer: 'cus_known')
      stub_subscription_list('cus_known', { 'sub_already' => 'active' })
      stub_subscription_retrieve('sub_already', trialing_subscription.merge('id' => 'sub_already'))

      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_already_subscribed'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')

      subscription = account.reload.account_subscription

      # And the one Stripe knows about is now the one the app knows about.
      expect(subscription.stripe_subscription_id).to eq('sub_already')
      expect(subscription.access_state).to eq('trialing')
    end

    # G14: Stripe pages a customer's subscriptions, newest first. A page of
    # dead ones is not "nothing live" — the live one may be on the next page.
    it 'reads every page of the customer\'s subscriptions before selling another' do
      checkout_row!(customer: 'cus_known')
      dead = Array.new(10) { |i| ["sub_dead_#{i + 1}", 'canceled'] }.to_h
      stub_subscription_list('cus_known', dead, has_more: true)
      stub_subscription_list('cus_known', { 'sub_live' => 'active' }, starting_after: 'sub_dead_10')
      stub_subscription_retrieve('sub_live', trialing_subscription.merge('id' => 'sub_live'))

      post '/settings/billing/checkout'

      expect(flash[:alert]).to eq(I18n.t('billing_already_subscribed'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
      expect(account.reload.account_subscription.stripe_subscription_id).to eq('sub_live')
    end

    # G2: when the row names none of them, the survivor is decided the same
    # way every time — the EARLIEST on our price — and the rest are
    # duplicates, however Stripe orders the list.
    it 'keeps the earliest of two live subscriptions and cancels the later one' do
      checkout_row!(customer: 'cus_known')
      stub_subscription_list('cus_known',
                             { 'sub_late' => listed_subscription('sub_late', 'active', created: 2_000),
                               'sub_early' => listed_subscription('sub_early', 'active', created: 1_000) })
      stub_subscription_retrieve('sub_early', trialing_subscription.merge('id' => 'sub_early'))
      stub_duplicate('sub_late', trialing_subscription)
      cancel_call = stub_cancel('sub_late', trialing_subscription)

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      post '/settings/billing/checkout'

      expect(flash[:alert]).to eq(I18n.t('billing_already_subscribed'))
      expect(cancel_call).to have_been_requested
      expect(account.reload.account_subscription.stripe_subscription_id).to eq('sub_early')
    end

    # Q2: the Checkout door looks Stripe up before it sells anything, and what
    # it finds can be a duplicate whose money the app refuses to return on
    # its own (an invoice that names no payment at all, here). That refusal
    # is deliberate and permanent, and it used to come out of this action as
    # an unhandled error — a 500 page for a customer whose only crime was
    # pressing Upgrade. Nothing is sold, the duplicate is still cancelled,
    # the debt is written onto the row for the nightly sweep, the operator is
    # paged, and the customer gets the same neutral sentence as a Stripe
    # outage.
    it 'turns a duplicate refund the app refuses into a sentence, never a 500' do
      row = checkout_row!(customer: 'cus_known')
      collected = { id: 'in_no_payment', object: 'invoice', amount_paid: 3000, currency: 'usd', created: 1_788_411_000,
                    payments: { object: 'list', data: [] } }

      stub_subscription_list('cus_known',
                             { 'sub_late' => listed_subscription('sub_late', 'active', created: 2_000),
                               'sub_early' => listed_subscription('sub_early', 'active', created: 1_000) })
      stub_subscription_retrieve('sub_early', trialing_subscription.merge('id' => 'sub_early'))
      stub_duplicate('sub_late', trialing_subscription, invoice: collected)
      cancel_call = stub_cancel('sub_late', trialing_subscription, invoice: collected)
      stub_invoice_list('sub_late', [collected])

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)
      allow(ErrorReport).to receive(:error)

      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_provider_unreachable'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/refunds')
      expect(cancel_call).to have_been_requested
      expect(ErrorReport).to have_received(:error)
        .with(instance_of(StripeBilling::Linker::RefundUnavailable), hash_including(account_id: account.id))
      # The debt survives the rollback the refusal caused, so the sweep can
      # come back to it.
      expect(row.reload.refund_owed_subscription_id).to eq('sub_late')
    end

    # G3: a live subscription for some other product on the same Stripe
    # customer is not ours: it is neither adopted (no paid access for a
    # purchase that was not ours) nor cancelled (it is somebody's purchase).
    it 'neither adopts nor cancels a subscription for another product, and sells ours' do
      checkout_row!(customer: 'cus_known')
      stub_subscription_list('cus_known',
                             { 'sub_other' => listed_subscription('sub_other', 'active', price: 'price_other') })
      stub_checkout_create

      allow(ErrorReport).to receive(:warning)

      post '/settings/billing/checkout'

      expect(response).to redirect_to(checkout_url)
      expect(WebMock).not_to have_requested(:delete, %r{api\.stripe\.com/v1/subscriptions/})
      expect(account.reload.account_subscription.stripe_subscription_id).to be_nil
      expect(ErrorReport).to have_received(:warning)
        .with('foreign subscription sub_other on customer cus_known left alone', hash_including(:account_id))
    end

    # H8: a customer tagged with this account may already exist at Stripe (a
    # checkout that failed after Stripe answered). It is found and adopted,
    # never made twice.
    it 'adopts the Stripe customer already tagged with the account instead of creating another' do
      stub_customer_search(['cus_found'])
      stub_customer_create
      stub_checkout_create

      post '/settings/billing/checkout'

      expect(response).to redirect_to(checkout_url)
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/customers')
      expect(account.reload.account_subscription.stripe_customer_id).to eq('cus_found')
      expect(posted('https://api.stripe.com/v1/checkout/sessions')['customer']).to eq('cus_found')
    end

    it 'adopts the existing customer when Stripe refuses the account key, never inventing a new key' do
      stub_customer_search([], ['cus_found'])
      stub_request(:post, 'https://api.stripe.com/v1/customers')
        .to_return(status: 400,
                   body: { error: { type: 'idempotency_error',
                                    message: 'Keys for idempotent requests can only be used once' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
      stub_checkout_create

      post '/settings/billing/checkout'

      expect(response).to redirect_to(checkout_url)
      expect(WebMock).to have_requested(:post, 'https://api.stripe.com/v1/customers')
        .with(headers: { 'Idempotency-Key' => "customer-account-#{account.id}" }).once
      expect(account.reload.account_subscription.stripe_customer_id).to eq('cus_found')
    end

    it 'creates the customer with the account\'s first admin, whoever is clicking' do
      first_admin = admin_for(account)
      second_admin = create(:user, account:)
      act_as(second_admin)
      stub_customer_create
      stub_checkout_create

      post '/settings/billing/checkout'

      expect(posted('https://api.stripe.com/v1/customers')['email']).to eq(first_admin.email)
      expect(second_admin.email).not_to eq(first_admin.email)
    end

    # H3: a list that cannot be read to the end is no basis for "nothing
    # live": the sale is refused and a person is told.
    it 'refuses to sell when the customer\'s subscription list cannot be read to the end' do
      checkout_row!(customer: 'cus_known')
      stub_subscription_list('cus_known', { 'sub_dead' => 'canceled' }, has_more: true)
      stub_checkout_create
      allow(ErrorReport).to receive(:error)

      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_provider_unreachable'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
      expect(ErrorReport).to have_received(:error)
        .with(an_instance_of(StripeBilling::ListIncomplete), hash_including(account_id: account.id))
    end

    # G4: the seats are part of the key, so a retry after a seat change is a
    # different request and gets a fresh session rather than a stale one.
    it 'gets a fresh Checkout session when the seats change within the same minute' do
      stub_customer_create
      stub_checkout_create

      post '/settings/billing/checkout'
      create(:user, account:)
      post '/settings/billing/checkout'

      keys = []
      expect(WebMock).to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
        .with { |request| keys << request.headers['Idempotency-Key'] }.twice
      expect(keys.uniq.size).to eq(2)
      expect(keys).to all(match(/\Acheckout-#{account.id}-[12]-true-\d{12}\z/))
      # And the customer, keyed on the account alone, was made exactly once.
      expect(WebMock).to have_requested(:post, 'https://api.stripe.com/v1/customers')
        .with(headers: { 'Idempotency-Key' => "customer-account-#{account.id}" }).once
    end

    # G1: another worker holding this account's row past the lock timeout
    # is a sentence, never a 500.
    it 'turns a lock wait timeout into a sentence' do
      allow(StripeBilling::Linker).to receive(:with_account_lock).and_raise(ActiveRecord::LockWaitTimeout)
      allow(ErrorReport).to receive(:warning)

      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_provider_unreachable'))
    end

    # The key covers the whole body it belongs to: reusing it after a seat
    # changed is what Stripe calls an idempotency error, and telling the
    # customer the provider is unreachable would be a lie.
    it 'keys the Checkout on the seats and the trial, and retries once when Stripe rejects a reused key' do
      create(:user, account:) # two seats
      stub_customer_create

      stub_request(:post, 'https://api.stripe.com/v1/checkout/sessions')
        .to_return({ status: 400,
                     body: { error: { type: 'idempotency_error',
                                      message: 'Keys for idempotent requests can only be used once' } }.to_json,
                     headers: { 'Content-Type' => 'application/json' } },
                   stripe_json(id: 'cs_test_fixture', object: 'checkout.session', url: checkout_url))

      post '/settings/billing/checkout'

      expect(response).to redirect_to(checkout_url)
      expect(WebMock).to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
        .with(headers: { 'Idempotency-Key' => /\Acheckout-#{account.id}-2-true-\d{12}\z/ }).once
      expect(WebMock).to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions').twice
    end

    # X5: "has this account had its trial?" was answered when the request came
    # in, and the Checkout session is created a moment later under the
    # account's row lock. In between, the webhook for the customer's FIRST
    # Checkout — completed in another tab, or a click whose page they went
    # back from — stamps `trial_used_at`. Selling on the stale answer handed
    # them a second 14-day trial and broke the app's own "one trial per
    # account, ever" rule at the only door that can sell one. The question is
    # asked again, on the row the lock has just re-read.
    it 'never sells a second trial when the first one is stamped while the click is in flight' do
      row = checkout_row!(customer: 'cus_known')
      stub_checkout_create

      # The concurrent webhook, landing in exactly that window: after the
      # before_action read the row, before the lock re-reads it.
      allow(StripeBilling::Linker).to receive(:with_account_lock).and_wrap_original do |original, record, &block|
        AccountSubscription.where(id: record.id).update_all(trial_used_at: Time.current)

        original.call(record, &block)
      end

      post '/settings/billing/checkout'

      expect(response).to redirect_to(checkout_url)

      session = posted('https://api.stripe.com/v1/checkout/sessions')

      expect(session['subscription_data']).not_to have_key('trial_period_days')
      expect(session['subscription_data']).not_to have_key('trial_settings')
      # The key carries the trial answer too, so a stale one is visible there
      # as well as in the body.
      expect(WebMock).to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
        .with(headers: { 'Idempotency-Key' => /\Acheckout-#{account.id}-1-false-\d{12}\z/ })
      expect(row.reload.trial_used_at).to be_present
    end

    it 'labels the free card as the plan\'s limits, and says so when the account has its own' do
      expect(page.at('[data-billing-free-limits-label]').text.strip).to eq(I18n.t('billing_free_plan_limits'))
      expect(page.at('[data-billing-custom-limits]')).to be_nil

      AccountLimitOverride.create!(account:, completions_per_month: 50)

      expect(page.at('[data-billing-custom-limits]').text.strip).to eq(I18n.t('billing_custom_limits_note'))
    end

    it 'turns a Stripe outage into a sentence, never a 500' do
      stub_request(:post, 'https://api.stripe.com/v1/customers').to_raise(Stripe::APIConnectionError)

      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_provider_unreachable'))
    end

    it 'has nothing to open in the Customer Portal yet' do
      post '/settings/billing/portal'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_no_customer_yet'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/billing_portal/sessions')
    end
  end

  # C1 (review 7). The deletion has been asked for and the 90-day window is
  # running: the subscription was cancelled with the request and the mail
  # promised no further charge. Buying again here would break that promise AND
  # jam the clean-up — on day 90 the purge refuses to destroy an account that
  # is still being charged, releases its claim and pages the operator, and
  # does the same every night after that while the card keeps being billed for
  # an account nobody may write to. So both doors to Stripe are shut, with the
  # one sentence that says what to do instead.
  describe 'an account scheduled for deletion' do
    before do
      account.update!(deletion_requested_at: Time.current, purge_scheduled_for: 90.days.from_now,
                      suspended_at: Time.current, suspension_reason: 'deletion')
      act_as(admin_for(account))
    end

    it 'says to cancel the deletion first instead of offering a button that would be refused' do
      doc = page

      expect(doc.at('[data-billing-banner="pending_deletion"]').text.strip)
        .to eq(I18n.t('billing_refused_pending_deletion'))
      expect(doc.at('[data-billing-checkout-button]')).to be_nil
      expect(doc.at('[data-billing-portal-button]')).to be_nil
    end

    it 'refuses Checkout and the Customer Portal without asking Stripe anything' do
      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_refused_pending_deletion'))

      post '/settings/billing/portal'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_refused_pending_deletion'))

      expect(WebMock).not_to have_requested(:any, %r{\Ahttps://api\.stripe\.com/})
      expect(AccountSubscription.count).to eq(0)
    end
  end

  describe 'an account whose free trial is already spent' do
    before do
      create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                    stripe_status: 'canceled', stripe_customer_id: 'cus_spent',
                                    stripe_subscription_id: 'sub_spent',
                                    trial_used_at: 2.months.ago, current_period_end: 1.month.ago)
      act_as(admin_for(account))
    end

    it 'says the subscription ended, offers an upgrade and never asks Stripe for a second trial' do
      doc = page

      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('ended')
      expect(doc.at('[data-billing-ended-banner]').text).to include(
        I18n.t('billing_ended_on', date: I18n.l(1.month.ago.to_date, format: :long))
      )
      expect(doc.at('[data-billing-trial-used]').text).to eq(I18n.t('billing_trial_used'))
      expect(doc.at('[data-billing-checkout-button]').text.strip).to eq(I18n.t('upgrade_to_paid'))

      stub_checkout_create

      post '/settings/billing/checkout'

      session = posted('https://api.stripe.com/v1/checkout/sessions')
      expect(session['subscription_data']).not_to have_key('trial_period_days')
      expect(session['subscription_data']).not_to have_key('trial_settings')
      # The customer was already known: no second customer is created.
      expect(session['customer']).to eq('cus_spent')
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/customers')
    end
  end

  describe 'an account on trial' do
    before do
      stripe_trialing!(account, seats: 1)
      act_as(admin_for(account))
    end

    it 'shows the trial, the end date and what it will cost, with only the portal button' do
      doc = page

      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('trialing')
      expect(doc.at('[data-billing-state-badge]').text).to eq(I18n.t('billing_state_trialing'))
      expect(doc.at('[data-billing-headline]').text.strip).to eq(
        I18n.t('billing_trial_ends_on', date: I18n.l(12.days.from_now.to_date, format: :long))
      )
      expect(doc.at('[data-billing-seats]').text.strip).to eq('1')
      expect(doc.at('[data-billing-amount]').text.strip).to eq(
        I18n.t('billing_then_amount_per_month', total: 10, price: 10)
      )
      expect(doc.at('[data-billing-portal-button]').text.strip).to eq(I18n.t('manage_billing'))
      expect(doc.at('[data-billing-checkout-button]')).to be_nil
    end

    it 'refuses a second Checkout without ever calling Stripe' do
      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_already_subscribed'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/customers')
    end

    it 'opens the Customer Portal with the configuration from the environment' do
      stub_portal_create

      post '/settings/billing/portal'

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(portal_url)

      session = posted('https://api.stripe.com/v1/billing_portal/sessions')
      expect(session['customer']).to eq("cus_#{account.id}")
      expect(session['configuration']).to eq(portal_configuration_id)
      expect(session['return_url']).to end_with('/settings/billing')
    end

    # The portal link IS the credential — it signs whoever opens it into this
    # customer's billing — and Rails logs every redirect destination at INFO.
    # The line the log gets must not be usable.
    it 'keeps the Customer Portal link out of the log' do
      stub_portal_create

      logged = []

      ActiveSupport::Notifications.subscribed(->(*, payload) { logged << payload[:location] },
                                              'redirect_to.action_controller') do
        post '/settings/billing/portal'
      end

      expect(response).to redirect_to(portal_url)
      expect(logged).to eq(['[FILTERED]'])
    end
  end

  describe 'the states a subscription can be in' do
    before { act_as(admin_for(account)) }

    it 'warns about a failed payment and keeps the portal reachable' do
      create(:account_subscription, account:, access_state: 'past_due', status: 'past_due',
                                    stripe_customer_id: 'cus_x', stripe_subscription_id: 'sub_x',
                                    past_due_since: 2.days.ago, current_period_end: 5.days.from_now)

      doc = page

      expect(doc.at('[data-billing-banner="past_due"]').text).to include(I18n.t('billing_past_due_banner'))
      expect(doc.at('[data-billing-portal-button]')).to be_present
    end

    it 'says paid features are off while billing is suspended' do
      create(:account_subscription, account:, access_state: 'suspended', status: 'unpaid',
                                    stripe_customer_id: 'cus_x', stripe_subscription_id: 'sub_x')

      doc = page

      expect(doc.at('[data-billing-banner="suspended"]').text)
        .to include(I18n.t('billing_suspended_banner', days: BillingLifecycle::PAST_DUE_GRACE_DAYS))
      expect(doc.at('[data-billing-banner="suspended"]').text)
        .to include("#{BillingLifecycle::PAST_DUE_GRACE_DAYS}-day grace period")
      expect(doc.at('[data-billing-portal-button]')).to be_present
    end

    # Review-6 S3: the state stays `past_due` (the payment problem is the more
    # urgent fact and drives the banner), but a subscription set to cancel
    # still ENDS on that date, and the card has to say so. Driven off
    # `cancel_at_period_end`, never off the access state.
    it 'still says when a past-due subscription set to cancel will end' do
      create(:account_subscription, account:, access_state: 'past_due', status: 'past_due',
                                    cancel_at_period_end: true, stripe_customer_id: 'cus_x',
                                    stripe_subscription_id: 'sub_x', past_due_since: 2.days.ago,
                                    current_period_end: 6.days.from_now)

      doc = page

      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('past_due')
      expect(doc.at('[data-billing-banner="past_due"]')).to be_present
      expect(doc.at('[data-billing-headline]').text.strip).to eq(
        I18n.t('billing_cancels_on', date: I18n.l(6.days.from_now.to_date, format: :long))
      )
    end

    it 'says when a cancelling subscription ends and that it can be resumed' do
      create(:account_subscription, account:, access_state: 'canceling', status: 'active',
                                    cancel_at_period_end: true, stripe_customer_id: 'cus_x',
                                    stripe_subscription_id: 'sub_x', current_period_end: 9.days.from_now)

      doc = page

      expect(doc.at('[data-billing-headline]').text.strip).to eq(
        I18n.t('billing_cancels_on', date: I18n.l(9.days.from_now.to_date, format: :long))
      )
      expect(doc.text).to include(I18n.t('billing_resume_hint'))
    end

    it 'shows the renewal date and the monthly amount for a paid account' do
      create(:account_subscription, account:, access_state: 'active', status: 'active', quantity: 3,
                                    stripe_customer_id: 'cus_x', stripe_subscription_id: 'sub_x',
                                    current_period_end: 20.days.from_now)
      create_list(:user, 2, account:)

      doc = page

      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('active')
      expect(doc.at('[data-billing-headline]').text.strip).to eq(
        I18n.t('billing_renews_on', date: I18n.l(20.days.from_now.to_date, format: :long))
      )
      expect(doc.at('[data-billing-seats]').text.strip).to eq('3')
      expect(doc.at('[data-billing-amount]').text.strip).to eq(
        I18n.t('billing_amount_per_month', total: 30, price: 10)
      )
    end

    # Seats are frozen at Checkout: what Stripe bills and who is in the
    # account can differ, and the page has to quote the invoice.
    #
    # Session 7 Phase B replaced the bare "N people in your account" line with
    # the seats card the seat flow needs: seats billed, seats occupied, the
    # invitations holding one, and the way to Settings → Users.
    it 'quotes the seats Stripe bills, and names who is using them' do
      create(:account_subscription, account:, access_state: 'active', status: 'active', quantity: 5,
                                    stripe_status: 'active', stripe_customer_id: 'cus_x',
                                    stripe_subscription_id: 'sub_x', current_period_end: 20.days.from_now)
      create(:user, account:) # two people, five seats billed
      create(:account_invite, account:) # and one seat held for somebody on the way

      doc = page

      expect(doc.at('[data-billing-seats]').text.strip).to eq('5')
      expect(doc.at('[data-billing-amount]').text.strip).to eq(
        I18n.t('billing_amount_per_month', total: 50, price: 10)
      )
      expect(doc.at('[data-billing-seats-in-use]').text).to include(
        I18n.t('billing_seats_summary_pending', seats: 5, in_use: 3, pending: 1)
      )
      expect(doc.at('[data-billing-seats-in-use]').at('a')['href']).to eq('/settings/users')
    end

    # An immediately cancelled subscription keeps a billing period that runs
    # weeks into the future; the banner used to read that as the end date.
    it 'says when the subscription ended, not when its period would have run out' do
      create(:account_subscription, account:, access_state: 'cancelled', status: 'canceled',
                                    stripe_status: 'canceled', stripe_customer_id: 'cus_x',
                                    stripe_subscription_id: 'sub_x', trial_used_at: 2.months.ago,
                                    ended_at: 40.days.ago, current_period_end: 10.days.from_now)

      expect(page.at('[data-billing-ended-banner]').text).to include(
        I18n.t('billing_ended_on', date: I18n.l(40.days.ago.to_date, format: :long))
      )
    end

    # `incomplete` is not paid access, but the subscription is alive at Stripe
    # and Checkout is refused for it: offering the buy button was a dead end.
    it 'offers the portal rather than a purchase the server would refuse while a payment is incomplete' do
      create(:account_subscription, account:, access_state: 'cancelled', status: 'incomplete',
                                    stripe_status: 'incomplete', quantity: 1, stripe_customer_id: 'cus_x',
                                    stripe_subscription_id: 'sub_x')

      doc = page

      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('incomplete')
      expect(doc.at('[data-billing-headline]').text.strip).to eq(I18n.t('billing_incomplete_headline'))
      expect(doc.at('[data-billing-portal-button]')).to be_present
      expect(doc.at('[data-billing-checkout-button]')).to be_nil

      post '/settings/billing/checkout'

      # Its own sentence: "you already have an active subscription" is not
      # what happened to somebody whose first payment never finished.
      expect(flash[:alert]).to eq(I18n.t('billing_refused_incomplete'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
    end

    # And the third refusal: a frozen account is not "already subscribed"
    # either — it is behind on an invoice, and the sentence says which door
    # settles it.
    it 'tells a suspended account to pay the open invoice rather than sell it a second subscription' do
      create(:account_subscription, account:, access_state: 'suspended', status: 'unpaid',
                                    stripe_status: 'unpaid', stripe_customer_id: 'cus_x',
                                    stripe_subscription_id: 'sub_x')

      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_refused_suspended'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
    end

    # A trial the customer cancelled while it was still running. Stripe reads
    # it as `canceling`, so the card used to quote "$10 per month" beside a
    # cancellation date and no trial note at all — a price for a charge that
    # is never going to be taken.
    it 'says a cancelled trial ends with no charge instead of quoting a monthly price' do
      create(:account_subscription, account:, access_state: 'canceling', status: 'trialing',
                                    stripe_status: 'trialing', cancel_at_period_end: true, quantity: 1,
                                    stripe_customer_id: 'cus_x', stripe_subscription_id: 'sub_x',
                                    trial_end: 8.days.from_now, current_period_end: 8.days.from_now,
                                    trial_used_at: Time.current)

      doc = page

      expect(doc.at('[data-billing-headline]').text.strip).to eq(
        I18n.t('billing_trial_cancels_on', date: I18n.l(8.days.from_now.to_date, format: :long))
      )
      expect(doc.at('[data-billing-amount]').text.strip).to eq(I18n.t('billing_trial_no_charge'))
      expect(doc.at('[data-billing-amount]').text).not_to include('$10 per month')
      expect(doc.text).to include(I18n.t('billing_resume_hint'))
    end

    # The same trial, cancelled the way the Customer Portal actually does it
    # (session 10 walk, W1): Stripe leaves `cancel_at_period_end` false and
    # names the date in `cancel_at`. The card has to read that date — while
    # the app read the flag alone the page still said "your free trial ends on
    # the 20th — then $20 per month" to somebody who had just cancelled.
    it 'says a trial cancelled from the Customer Portal ends with no charge' do
      create(:account_subscription, account:, access_state: 'canceling', status: 'trialing',
                                    stripe_status: 'trialing', cancel_at_period_end: false, quantity: 2,
                                    stripe_customer_id: 'cus_x', stripe_subscription_id: 'sub_x',
                                    cancel_at: 11.days.from_now, trial_end: 11.days.from_now,
                                    current_period_end: 11.days.from_now, trial_used_at: Time.current)

      doc = page

      expect(doc.at('[data-billing-card]')['data-billing-card']).to eq('canceling')
      expect(doc.at('[data-billing-headline]').text.strip).to eq(
        I18n.t('billing_trial_cancels_on', date: I18n.l(11.days.from_now.to_date, format: :long))
      )
      expect(doc.at('[data-billing-amount]').text.strip).to eq(I18n.t('billing_trial_no_charge'))
      expect(doc.text).to include(I18n.t('billing_resume_hint'))
      expect(doc.at('[data-billing-portal-button]')).to be_present
    end

    # And the same fact on a paid subscription: Stripe ends it on the date it
    # was given, which is not always the end of the period the customer is in.
    # The card used to fall back to a vague "at the end of the current period"
    # for exactly this row, because only the flag was read.
    it 'names the date a subscription ends on when it is not the end of the period' do
      create(:account_subscription, account:, access_state: 'canceling', status: 'active',
                                    stripe_status: 'active', cancel_at_period_end: false, quantity: 1,
                                    stripe_customer_id: 'cus_x', stripe_subscription_id: 'sub_x',
                                    cancel_at: 5.days.from_now, current_period_end: 25.days.from_now)

      doc = page

      expect(doc.at('[data-billing-headline]').text.strip).to eq(
        I18n.t('billing_cancels_on', date: I18n.l(5.days.from_now.to_date, format: :long))
      )
      expect(doc.text).to include(I18n.t('billing_resume_hint'))
    end

    # Every other settings page renders dates in the account's timezone; a
    # trial ending at 02:00 UTC is still today for a customer in New York.
    it 'shows dates in the account\'s own timezone' do
      account.update!(timezone: 'America/New_York')
      create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                    stripe_status: 'trialing', quantity: 1, stripe_customer_id: 'cus_x',
                                    stripe_subscription_id: 'sub_x', trial_end: Time.utc(2026, 10, 1, 2, 0))

      expect(page.at('[data-billing-headline]').text.strip).to eq(
        I18n.t('billing_trial_ends_on', date: I18n.l(Date.new(2026, 9, 30), format: :long))
      )
    end

    it 'offers nothing to buy or manage on a plan the operator granted by hand' do
      create(:account_subscription, account:, access_state: 'active', status: 'manual')

      doc = page

      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('manual')
      expect(doc.at('[data-billing-card="manual"]').text).to include(I18n.t('billing_managed_by_operator'))
      expect(doc.at('[data-billing-checkout-button]')).to be_nil
      expect(doc.at('[data-billing-portal-button]')).to be_nil

      # Not just the buttons: the actions themselves refuse.
      post '/settings/billing/checkout'

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_managed_by_operator'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')

      post '/settings/billing/portal'

      expect(flash[:alert]).to eq(I18n.t('billing_managed_by_operator'))
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/billing_portal/sessions')
    end
  end

  describe 'coming back from Checkout' do
    before do
      act_as(admin_for(account))
      # The session is only a trigger: the subscription is re-fetched through
      # the same locked path every webhook uses.
      stub_subscription_retrieve(trialing_subscription['id'], trialing_subscription)
    end

    it 'links the subscription so the page tells the truth before the webhook lands' do
      checkout_row!(customer: trialing_subscription['customer'])
      stub_checkout_retrieve('cs_test_ok', reference: account.id.to_s)

      get '/settings/billing/return', params: { session_id: 'cs_test_ok' }

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:notice]).to eq("Your #{StripeBilling::TRIAL_PERIOD_DAYS}-day trial has started.")

      subscription = account.reload.account_subscription
      expect(subscription.access_state).to eq('trialing')
      expect(subscription.stripe_subscription_id).to eq(trialing_subscription['id'])
      expect(subscription.quantity).to eq(3)
      expect(subscription.trial_used_at).to be_present
      expect(Plans.key_for(account)).to eq(Plans::PAID)

      expect(page.at('[data-billing-state]')['data-billing-state']).to eq('trialing')
    end

    # The green sentence used to be sent for every PAID access state, and two
    # of them are not "your subscription is active": a subscription whose
    # first renewal already failed is past_due, and one Stripe hands back with
    # the cancellation flag on ends at the period end. Both contradicted the
    # state card the customer was looking at on the same page.
    it 'does not call a past-due subscription active on the way back from Checkout' do
      checkout_row!(customer: trialing_subscription['customer'])
      past_due = trialing_subscription.merge('status' => 'past_due')
      stub_subscription_retrieve(past_due['id'], past_due)
      stub_checkout_retrieve('cs_test_past_due', reference: account.id.to_s, subscription: past_due)

      get '/settings/billing/return', params: { session_id: 'cs_test_past_due' }

      expect(account.reload.account_subscription.access_state).to eq('past_due')
      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to eq(I18n.t('billing_checkout_past_due'))
    end

    it 'says a subscription already set to cancel ends at the period end rather than calling it active' do
      checkout_row!(customer: trialing_subscription['customer'])
      canceling = trialing_subscription.merge('status' => 'active', 'cancel_at_period_end' => true)
      stub_subscription_retrieve(canceling['id'], canceling)
      stub_checkout_retrieve('cs_test_canceling', reference: account.id.to_s, subscription: canceling)

      get '/settings/billing/return', params: { session_id: 'cs_test_canceling' }

      expect(account.reload.account_subscription.access_state).to eq('canceling')
      expect(flash[:notice]).to eq(I18n.t('billing_checkout_canceling'))
      expect(flash[:notice]).not_to eq(I18n.t('billing_subscription_active'))
    end

    it 'ignores a Checkout session that belongs to somebody else' do
      other = create(:account)
      checkout_row!(customer: trialing_subscription['customer'])
      stub_checkout_retrieve('cs_test_other', reference: other.id.to_s)

      get '/settings/billing/return', params: { session_id: 'cs_test_other' }

      expect(flash[:alert]).to eq(I18n.t('billing_checkout_unmatched'))
      expect(account.reload.account_subscription.stripe_subscription_id).to be_nil
      expect(Plans.key_for(account)).to eq(Plans::FREE)
    end

    # G6: Checkout made the row and the customer before the session existed.
    # A session for an account with no row — or with no customer on it — is
    # not a purchase this app made, and is never the reason to create one.
    it 'refuses a session when the account has no Checkout row, and creates none' do
      stub_checkout_retrieve('cs_test_orphan', reference: account.id.to_s)

      allow(ErrorReport).to receive(:warning)

      get '/settings/billing/return', params: { session_id: 'cs_test_orphan' }

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_checkout_unmatched'))
      expect(flash[:notice]).to be_nil
      expect(account.reload.account_subscription).to be_nil
      expect(ErrorReport).to have_received(:warning)
        .with(/could not be matched/, hash_including(account_id: account.id))
      expect(WebMock).not_to have_requested(:get, %r{api\.stripe\.com/v1/subscriptions/})
    end

    # S4 (Session 6). A bookmarked, mistyped or made-up return URL asks Stripe
    # about a session it has never heard of. That is not an outage: it used to
    # meet the controller's Stripe handler, tell the customer the payment
    # provider was unreachable and page us with an ErrorReport.error. It is the
    # same answer as a session that turns out to be somebody else's.
    it 'treats a stale or forged session id as unmatched rather than an outage' do
      checkout_row!(customer: trialing_subscription['customer'])
      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/checkout/sessions/cs_test_gone})
        .to_return(status: 404,
                   body: { error: { type: 'invalid_request_error', code: 'resource_missing',
                                    message: 'No such checkout.session: cs_test_gone' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      allow(ErrorReport).to receive(:warning)
      allow(ErrorReport).to receive(:error)

      get '/settings/billing/return', params: { session_id: 'cs_test_gone' }

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_checkout_unmatched'))
      expect(flash[:alert]).not_to eq(I18n.t('billing_provider_unreachable'))
      expect(ErrorReport).to have_received(:warning).with(/could not be matched/, hash_including(:account_id))
      expect(ErrorReport).not_to have_received(:error)
      expect(account.reload.account_subscription.stripe_subscription_id).to be_nil
    end

    # And a Stripe request that is genuinely wrong on our side still surfaces:
    # only `resource_missing` is a stale bookmark.
    it 'still reports another invalid-request failure as an outage' do
      checkout_row!(customer: trialing_subscription['customer'])
      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/checkout/sessions/cs_test_bad})
        .to_return(status: 400,
                   body: { error: { type: 'invalid_request_error', code: 'parameter_unknown',
                                    message: 'Received unknown parameter' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      allow(ErrorReport).to receive(:error)

      get '/settings/billing/return', params: { session_id: 'cs_test_bad' }

      expect(flash[:alert]).to eq(I18n.t('billing_provider_unreachable'))
      expect(ErrorReport).to have_received(:error)
        .with(kind_of(Stripe::InvalidRequestError), hash_including(:account_id))
    end

    it 'refuses a session whose customer is blank, touching no row' do
      row = checkout_row!(customer: 'cus_ours')
      stub_checkout_retrieve('cs_test_blank', reference: account.id.to_s, customer: '')

      get '/settings/billing/return', params: { session_id: 'cs_test_blank' }

      expect(flash[:alert]).to eq(I18n.t('billing_checkout_unmatched'))
      expect(row.reload.stripe_subscription_id).to be_nil
      expect(row.stripe_customer_id).to eq('cus_ours')
      expect(row.access_state).to eq('cancelled')
    end

    it 'refuses a session whose subscription our Checkout tagged for another account' do
      row = checkout_row!(customer: trialing_subscription['customer'])
      other = create(:account)
      stub_checkout_retrieve('cs_test_tagged', reference: account.id.to_s,
                                               subscription: trialing_subscription.merge(
                                                 'metadata' => { 'esigncenter_account_id' => other.id.to_s }
                                               ))

      get '/settings/billing/return', params: { session_id: 'cs_test_tagged' }

      expect(flash[:alert]).to eq(I18n.t('billing_checkout_unmatched'))
      expect(row.reload.stripe_subscription_id).to be_nil
    end

    # A `session_id` in the query string proves nothing on its own: it is a
    # bookmarkable URL, and the session behind it may be somebody else's, half
    # finished, or a payment that was never a subscription.
    it 'ignores a session that was never completed' do
      row = checkout_row!(customer: trialing_subscription['customer'])
      stub_checkout_retrieve('cs_test_open', reference: account.id.to_s, status: 'open')

      get '/settings/billing/return', params: { session_id: 'cs_test_open' }

      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to eq(I18n.t('billing_checkout_unmatched'))
      expect(row.reload.stripe_subscription_id).to be_nil
    end

    it 'ignores a session for a customer this account does not own' do
      checkout_row!(customer: 'cus_ours')
      stub_checkout_retrieve('cs_test_stranger', reference: account.id.to_s, customer: 'cus_somebody_else')

      get '/settings/billing/return', params: { session_id: 'cs_test_stranger' }

      expect(flash[:notice]).to be_nil
      expect(account.reload.account_subscription.stripe_subscription_id).to be_nil
    end

    # The money case: the browser lands here before Sidekiq drains, so this is
    # where a second completed Checkout used to overwrite the subscription
    # that is charging the card — and, by rewriting the id, disarm the
    # webhook's duplicate guard so the first one billed forever.
    it 'cancels the duplicate rather than repointing a row that already pays' do
      subscription = trialing_subscription
      row = create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                          stripe_status: 'trialing', quantity: 3,
                                          stripe_customer_id: subscription['customer'],
                                          stripe_subscription_id: 'sub_first_one', trial_used_at: 1.day.ago)

      # The one the row holds came first, so it is the survivor (H6).
      stub_subscription_retrieve('sub_first_one', subscription.merge('id' => 'sub_first_one',
                                                                     'created' => subscription['created'] - 100))
      stub_checkout_retrieve('cs_test_second', reference: account.id.to_s)
      stub_duplicate(subscription['id'], subscription)

      cancel_call = stub_cancel(subscription['id'], subscription)

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      get '/settings/billing/return', params: { session_id: 'cs_test_second' }

      expect(cancel_call).to have_been_requested
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/refunds')
      expect(flash[:notice]).to eq(I18n.t('billing_duplicate_cancelled'))
      expect(row.reload.stripe_subscription_id).to eq('sub_first_one')
      expect(row.access_state).to eq('trialing')
    end

    # G5: with the trial spent, Checkout charged the duplicate's first
    # invoice before the browser came back. The customer is told the money
    # went back, and how much.
    it 'refunds a duplicate that already charged the card, and says how much' do
      subscription = trialing_subscription.merge('status' => 'active', 'trial_end' => nil)
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', quantity: 3,
                                          stripe_customer_id: subscription['customer'],
                                          stripe_subscription_id: 'sub_first_one', trial_used_at: 1.month.ago)

      stub_subscription_retrieve('sub_first_one', subscription.merge('id' => 'sub_first_one',
                                                                     'created' => subscription['created'] - 100))
      stub_checkout_retrieve('cs_test_paid_twice', reference: account.id.to_s, subscription:)
      invoice = paid_invoice(subscription['id'], amount: 3000)
      stub_duplicate(subscription['id'], subscription, invoice:)
      stub_cancel(subscription['id'], subscription, invoice:)
      stub_invoice_list(subscription['id'], [invoice])
      stub_payment_intent("pi_#{subscription['id']}", amount: 3000)
      refund_call = stub_request(:post, 'https://api.stripe.com/v1/refunds')
                    .with(body: hash_including('payment_intent' => "pi_#{subscription['id']}",
                                               'reason' => 'duplicate'))
                    .to_return(**stripe_json(id: 're_dup', object: 'refund', amount: 3000, currency: 'usd'))

      allow(OperatorAlert).to receive(:deliver).and_return(true)
      allow(ErrorReport).to receive(:warning)

      get '/settings/billing/return', params: { session_id: 'cs_test_paid_twice' }

      expect(refund_call).to have_been_requested
      expect(flash[:notice]).to eq(I18n.t('billing_duplicate_refunded', amount: '$30.00'))
      expect(flash[:notice]).to include('$30.00')
      expect(row.reload.stripe_subscription_id).to eq('sub_first_one')
    end

    # A subscription that is not paid access yet says so on the card; a green
    # "your subscription is active" over it would be a lie.
    it 'says nothing when the subscription came back incomplete' do
      incomplete = trialing_subscription.merge('status' => 'incomplete', 'trial_end' => nil)
      checkout_row!(customer: incomplete['customer'])
      stub_subscription_retrieve(incomplete['id'], incomplete)
      stub_checkout_retrieve('cs_test_incomplete', reference: account.id.to_s, subscription: incomplete)

      get '/settings/billing/return', params: { session_id: 'cs_test_incomplete' }

      expect(flash[:notice]).to be_nil
      expect(account.reload.account_subscription.stripe_status).to eq('incomplete')
    end

    # The return never creates a row: Checkout did that before the session
    # existed. Two tabs coming back at once therefore have nothing to race
    # for, and a session naming no customer is simply not ours (G6/G16b).
    it 'creates no row for a session that names no customer, whatever else it says' do
      subscription = trialing_subscription.merge('customer' => nil)
      stub_subscription_retrieve(subscription['id'], subscription)
      stub_checkout_retrieve('cs_test_nobody', reference: account.id.to_s, subscription:, customer: '')

      get '/settings/billing/return', params: { session_id: 'cs_test_nobody' }

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_checkout_unmatched'))
      expect(account.reload.account_subscription).to be_nil
      expect(WebMock).not_to have_requested(:get, %r{api\.stripe\.com/v1/subscriptions/})
    end

    it 'says nothing was charged when Checkout was abandoned' do
      get '/settings/billing/return', params: { cancelled: 1 }

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:notice]).to eq(I18n.t('billing_checkout_cancelled'))
      expect(account.reload.account_subscription).to be_nil
      expect(page.at('[data-billing-state]')['data-billing-state']).to eq('free')
    end
  end

  describe 'a child account billed through its parent' do
    let(:child) do
      Account.create!(name: 'Team A', locale: 'en-US', timezone: 'UTC',
                      linked_account_account: AccountLinkedAccount.new(account_type: :linked, account:))
    end

    it 'sees the parent\'s subscription, is told who pays, and gets no buttons' do
      stripe_trialing!(account, seats: 2)
      act_as(admin_for(child))

      doc = page

      expect(doc.at('[data-billing-parent-banner]').text).to include(
        I18n.t('billing_managed_by_parent', account: account.name)
      )
      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('trialing')
      expect(doc.at('[data-billing-checkout-button]')).to be_nil
      expect(doc.at('[data-billing-portal-button]')).to be_nil
    end

    # The buttons were the only thing stopping a child's admin from buying on
    # the parent — or opening the parent's Customer Portal, where the card,
    # the invoices and the cancel button live. A direct POST is not a button.
    it 'cannot buy on the parent, open the parent\'s portal or apply a session to it' do
      stripe_trialing!(account, seats: 2)
      act_as(admin_for(child))

      post '/settings/billing/checkout'
      expect(response).to have_http_status(:not_found)

      post '/settings/billing/portal'
      expect(response).to have_http_status(:not_found)

      get '/settings/billing/return', params: { session_id: 'cs_test_child' }
      expect(response).to have_http_status(:not_found)

      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
      expect(WebMock).not_to have_requested(:post, 'https://api.stripe.com/v1/billing_portal/sessions')
      expect(WebMock).not_to have_requested(:get, %r{api\.stripe\.com/v1/checkout/sessions/})
    end

    # And the upgrade call-to-action does not send them to a page they can
    # only read.
    it 'sends a child admin\'s upgrade call-to-action to usage, not to billing' do
      act_as(admin_for(child))

      expect(page('/settings/usage').at('[data-upgrade-cta]')['href']).to eq(Quotas::USAGE_PATH)
    end
  end

  describe 'the settings nav and the upgrade call-to-action' do
    it 'offers Billing to a customer admin and to nobody else' do
      act_as(admin_for(account))
      expect(page('/settings/usage').at('#account_settings_menu').css('a').pluck('href'))
        .to include('/settings/billing')

      internal = create(:account, :internal)
      act_as(admin_for(internal))
      expect(page('/settings/usage').at('#account_settings_menu').css('a').pluck('href'))
        .not_to include('/settings/billing')

      ENV['BILLING_ENABLED'] = 'false'
      act_as(admin_for(account))
      expect(page('/settings/usage').at('#account_settings_menu').css('a').pluck('href'))
        .not_to include('/settings/billing')
    end

    it 'points every upgrade call-to-action at the billing page, and at usage when there is none' do
      act_as(admin_for(account))

      expect(page('/settings/usage').at('[data-upgrade-cta]')['href']).to eq('/settings/billing')
      expect(page('/settings/api').at('[data-upgrade-cta]')['href']).to eq('/settings/billing')

      ENV['BILLING_ENABLED'] = 'false'

      expect(page('/settings/usage').at('[data-upgrade-cta]')['href']).to eq(Quotas::USAGE_PATH)

      # An editor cannot buy, so the call-to-action never sends them to a refusal.
      ENV['BILLING_ENABLED'] = 'true'
      template = create(:template, account:, author: admin_for(account))
      act_as(create(:user, :editor, account:))
      expect(page("/templates/#{template.id}/preferences").at('[data-upgrade-cta]')['href'])
        .to eq(Quotas::USAGE_PATH)
    end
  end
end

# G4: two first-ever Checkout clicks at the same moment — two real inserts
# racing for the unique account row, then the whole customer/list/session
# decision serialised on that row. What this proves: the clicks are
# serialised (one row, ONE customer created), and both Checkout requests
# carry the SAME idempotency key — which is what lets Stripe hand back one
# session; the session itself is stubbed here, so "one session" is Stripe's
# promise, not this example's. Runs without the wrapping test transaction
# so the row lock is taken between two real connections.
RSpec.describe 'Two Checkout clicks on one account', type: :request do
  self.use_transactional_tests = false

  let(:checkout_url) { 'https://checkout.stripe.com/c/pay/cs_test_fixture' }

  stash_env(*StripeBilling::CONFIG_KEYS.keys, 'BILLING_ENABLED')

  before do
    ENV['STRIPE_SECRET_KEY'] = 'sk_test_fake'
    ENV['STRIPE_PUBLISHABLE_KEY'] = 'pk_test_fake'
    ENV['STRIPE_WEBHOOK_SECRET'] = 'whsec_testsecret'
    ENV['STRIPE_PRICE_ID'] = 'price_1UAt8N4rEeOqtLcX1amJxYdZ'
    ENV['STRIPE_PORTAL_CONFIGURATION_ID'] = 'bpc_test'
    ENV['BILLING_ENABLED'] = 'true'
  end

  def stripe_json(body)
    { status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  it 'serialises two simultaneous first clicks: one row, one customer, identical Checkout keys' do
    account = create(:account)
    admin = create(:user, account:)

    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions\?})
      .to_return(**stripe_json(object: 'list', data: [], has_more: false))
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/customers/search})
      .to_return(**stripe_json(object: 'search_result', data: []))
    # The first click is slow at Stripe, so the second is certainly waiting on the row by then.
    stub_request(:post, 'https://api.stripe.com/v1/customers')
      .to_return do
        sleep(0.5)

        stripe_json(id: 'cus_once', object: 'customer')
      end
    stub_request(:post, 'https://api.stripe.com/v1/checkout/sessions')
      .to_return(**stripe_json(id: 'cs_test_fixture', object: 'checkout.session', url: checkout_url))

    # Two signed-in browser sessions of the same admin, each with its own
    # cookie jar; the sign-in itself happens one at a time.
    sessions = Array.new(2) do
      session = open_session
      sign_in(admin)
      session.get('/')
      session
    end

    barrier = Queue.new
    clicks = sessions.map do |session|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop

          session.post('/settings/billing/checkout')

          [session.response.status, session.response.location]
        end
      end
    end

    2.times { barrier << true }

    # `value` re-raises: a click that 500ed cannot hide behind the other.
    expect(clicks.map(&:value)).to all(eq([303, checkout_url]))

    expect(AccountSubscription.where(account_id: account.id).count).to eq(1)
    expect(AccountSubscription.find_by(account_id: account.id).stripe_customer_id).to eq('cus_once')
    expect(WebMock).to have_requested(:post, 'https://api.stripe.com/v1/customers').once

    keys = []
    expect(WebMock).to have_requested(:post, 'https://api.stripe.com/v1/checkout/sessions')
      .with { |request| keys << request.headers['Idempotency-Key'] }.twice
    expect(keys.uniq.size).to eq(1)
  ensure
    # Both clicks must be over before the account goes, whichever one failed —
    # and the account is re-read first: it cached "no subscription row" before
    # the clicks made one, and a stale cache would leave that row behind.
    clicks&.each { |click| click.join(20) }
    account&.reload&.destroy!
  end
end
