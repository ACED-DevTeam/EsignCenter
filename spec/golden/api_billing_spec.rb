# frozen_string_literal: true

# D79 uses the same captured Stripe subscriptions as the original billing
# suite. Only the items and dates are changed to represent the new products;
# WebMock refuses any request not explicitly answered here.
RSpec.describe 'API plan billing', type: :request do
  include_context 'with a Stripe test account'

  let(:stripe_state) { {} }
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:) }
  let(:business_price) { 'price_business' }
  let(:pack_price) { 'price_api_pack' }
  let(:period_end) { 20.days.from_now.change(usec: 0) }
  let!(:row) do
    create(:account_subscription, account:, access_state: 'active', status: 'active', stripe_status: 'active',
                                  stripe_subscription_id: subscription_a, stripe_customer_id: customer_a,
                                  stripe_price_id: fixture_price, stripe_item_id: 'si_seats', quantity: 1,
                                  current_period_end: period_end)
  end

  stash_env(*StripeBilling::OPTIONAL_CONFIG_KEYS)

  before do
    ENV['STRIPE_BUSINESS_PRICE_ID'] = business_price
    ENV['STRIPE_API_PACK_PRICE_ID'] = pack_price
    sign_in(admin)
  end

  def subscription(plan: 'paid', seats: 1, packs: 0, **overrides)
    body = JSON.parse(fixture_body('subscription-active')).merge('id' => subscription_a, 'customer' => customer_a)
    items = []
    items << stripe_item('si_business', business_price, 1) if plan == 'business'
    extra_seats = plan == 'business' ? seats - 1 : seats
    items << stripe_item('si_seats', fixture_price, extra_seats) if extra_seats.positive?
    items << stripe_item('si_packs', pack_price, packs) if packs.positive?
    body['items']['data'] = items
    body.merge(overrides.stringify_keys)
  end

  def stripe_item(id, price, quantity)
    template = JSON.parse(fixture_body('subscription-active'))['items']['data'].first
    template.merge('id' => id, 'price' => price, 'quantity' => quantity,
                   'current_period_start' => 10.days.ago.to_i, 'current_period_end' => period_end.to_i)
  end

  def stripe_json(body)
    { status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  def read_subscriptions(*bodies)
    stripe_state[:subscription] = bodies.first
    stub_request(:get, seat_subscription_url(subscription_a))
      .with(query: { 'expand' => StripeBilling::SUBSCRIPTION_EXPAND })
      .to_return { stripe_json(stripe_state[:subscription]) }
  end

  # Every mutation matches the ENTIRE request body. Adding an unsupported
  # pending/deleted pair, a credit, a proration date or a seat change fails.
  def write_subscription(body, expected)
    expected['items'] = expected['items'].values if expected['items'].is_a?(Hash)

    stub_request(:post, seat_subscription_url(subscription_a))
      .with(body: expected)
      .to_return do
        stripe_state[:subscription] = body
        stripe_json(body)
      end
  end

  after do
    WebMock::RequestRegistry.instance.requested_signatures.hash.each_key do |request|
      next unless request.method == :post && request.uri.host == 'api.stripe.com'

      body = URI.decode_www_form(request.body.to_s).to_h
      next unless body.any? { |key, value| key.end_with?('[deleted]') && value == 'true' }

      if body['payment_behavior'] == 'pending_if_incomplete'
        raise 'Stripe rejects pending_if_incomplete with a deleted item'
      end
    end
  end

  def pack_purchase
    ApiPackPurchase.order(:id).last
  end

  def pack_invoice(status = 'draft')
    { id: 'in_api_packs', object: 'invoice', customer: customer_a, status:, currency: 'usd',
      total: pack_purchase.amount_cents,
      metadata: { StripeBilling::PackPurchases::METADATA_KEY => pack_purchase.operation_key },
      lines: { data: [] }, status_transitions: { paid_at: status == 'paid' ? Time.current.to_i : nil } }
  end

  # A separate invoice has exactly one full-price line, no subscription,
  # no imported pending items, no taxes/discounts, and no period/seat changes.
  def stub_pack_invoice(paid: true)
    search = stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/invoices/search})
    search.with do |request|
      expect(request.uri.query_values).to eq(
        'query' => "metadata['esigncenter_api_pack_purchase']:'#{pack_purchase.operation_key}'", 'limit' => '1'
      )
      true
    end
    search.to_return do
      stripe_json(object: 'search_result', data: stripe_state[:invoice] ? [stripe_state[:invoice]] : [])
    end
    create = stub_request(:post, 'https://api.stripe.com/v1/invoices')
    create.with do |request|
      expect(Rack::Utils.parse_nested_query(request.body)).to eq(
        'customer' => customer_a, 'collection_method' => 'charge_automatically', 'auto_advance' => 'false',
        'pending_invoice_items_behavior' => 'exclude', 'automatic_tax' => { 'enabled' => 'false' },
        'metadata' => { 'esigncenter_api_pack_purchase' => pack_purchase.operation_key }
      )
      true
    end
    create.to_return do
      stripe_state[:invoice] = pack_invoice
      stripe_json(stripe_state[:invoice])
    end
    item = stub_request(:post, 'https://api.stripe.com/v1/invoiceitems')
    item.with do |request|
      expect(Rack::Utils.parse_nested_query(request.body)).to eq(
        'customer' => customer_a, 'invoice' => 'in_api_packs', 'amount' => pack_purchase.amount_cents.to_s,
        'currency' => 'usd', 'discountable' => 'false',
        'description' => "#{pack_purchase.added_quantity} API packs (50 completions each)",
        'metadata' => { 'esigncenter_api_pack_purchase' => pack_purchase.operation_key }
      )
      true
    end
    item.to_return { stripe_json(id: 'ii_api_packs', object: 'invoiceitem') }
    stub_request(:post, 'https://api.stripe.com/v1/invoices/in_api_packs/finalize')
      .with(body: { 'auto_advance' => 'false' }).to_return do
        stripe_state[:invoice] = pack_invoice('open')
        stripe_json(stripe_state[:invoice])
      end
    payment = stub_request(:post, 'https://api.stripe.com/v1/invoices/in_api_packs/pay')
      .with(body: { 'off_session' => 'true' }).to_return do
        stripe_state[:invoice] = pack_invoice(paid ? 'paid' : 'open')
        stripe_json(stripe_state[:invoice])
      end
    stub_request(:get, 'https://api.stripe.com/v1/invoices/in_api_packs')
      .to_return { stripe_json(stripe_state[:invoice]) }

    [create, item, payment]
  end

  describe 'subscription item mapping' do
    it 'maps the Business base, extra seats and API packs independently' do
      StripeBilling::SubscriptionSync.apply!(row, subscription(plan: 'business', seats: 4, packs: 3))

      expect(row.reload).to have_attributes(plan: 'business', quantity: 4, api_pack_quantity: 3,
                                            stripe_item_id: 'si_business', stripe_price_id: business_price)
      expect(Plans.key_for(account.reload)).to eq('business')
      expect(Quotas.limits_for(account).api_completions_per_month).to eq(650)
    end

    it 'maps one Business seat without a seat-price item and recognises it as ours' do
      body = subscription(plan: 'business')
      StripeBilling::SubscriptionSync.apply!(row, body)

      expect(row.quantity).to eq(1)
      expect(StripeBilling::SubscriptionPolicy.ours?(body, account.id)).to be(true)
    end

    it 'retains Paid compatibility when optional prices are absent' do
      StripeBilling::OPTIONAL_CONFIG_KEYS.each { |key| ENV.delete(key) }
      StripeBilling::SubscriptionSync.apply!(row, subscription(seats: 3))

      expect(StripeBilling.configured?).to be(true)
      expect(StripeBilling.business_available?).to be(false)
      expect(StripeBilling.api_packs_available?).to be(false)
      expect(StripeBilling::ConfigGuard.problems_with_config).to be_empty
      expect(row.reload).to have_attributes(plan: 'paid', quantity: 3, api_pack_quantity: 0)
      expect(Quotas.limits_for(account).api_completions_per_month).to eq(50)
    end

    it 'preserves a known Business base if its optional env variable is accidentally removed' do
      row.update!(plan: 'business', stripe_price_id: business_price, quantity: 3)
      ENV.delete('STRIPE_BUSINESS_PRICE_ID')
      StripeBilling::SubscriptionSync.apply!(row, subscription(plan: 'business', seats: 3))

      expect(row).to have_attributes(plan: 'business', quantity: 3, stripe_price_id: business_price)
    end

    it 'checks each configured optional price against its own monthly amount' do
      [[business_price, 4900], [pack_price, 1000]].each do |id, amount|
        stub_request(:get, "https://api.stripe.com/v1/prices/#{id}")
          .to_return(**stripe_json(id:, object: 'price', active: true, currency: 'usd', unit_amount: amount,
                                   recurring: { interval: 'month', interval_count: 1 }))
      end

      expect(StripeBilling::Checks.optional_price_rows.pluck(:result).uniq).to eq(['PASS'])
      stub_request(:get, "https://api.stripe.com/v1/prices/#{pack_price}")
        .to_return(**stripe_json(id: pack_price, object: 'price', active: true, currency: 'usd', unit_amount: 50,
                                 recurring: { interval: 'month', interval_count: 1 }))
      expect(StripeBilling::Checks.failed?(StripeBilling::Checks.optional_price_rows)).to be(true)
    end

    it 'grants Business trial allowance and ignores an unrelated item quantity' do
      body = subscription(plan: 'business', status: 'trialing')
      body['items']['data'] << stripe_item('si_other', 'price_foreign', 99)
      StripeBilling::SubscriptionSync.apply!(row, body)

      expect(row).to have_attributes(quantity: 1, api_pack_quantity: 0, access_state: 'trialing')
      expect(Quotas.limits_for(account).api_completions_per_month).to eq(500)
    end

    it 'does not retain removed capacity when the Stripe period has already renewed' do
      row.update!(api_pack_quantity: 3, current_period_end: 1.day.ago)
      StripeBilling::SubscriptionSync.apply!(row, subscription(packs: 1))

      expect(row.effective_api_pack_quantity).to eq(1)
    end

    it 'rejects optional price typos and overlapping prices' do
      ENV['STRIPE_BUSINESS_PRICE_ID'] = 'not_a_price'
      ENV['STRIPE_API_PACK_PRICE_ID'] = fixture_price

      expect(StripeBilling::ConfigGuard.problems_with_config).to include(
        'STRIPE_BUSINESS_PRICE_ID does not look like a Stripe price (expected price_)',
        'Stripe seat, Business and API pack prices must be distinct'
      )
    end
  end

  describe 'billing controls' do
    it 'switches Paid to Business with proration while keeping the same seat count' do
      row.update!(quantity: 3)
      read_subscriptions(subscription(seats: 3), subscription(plan: 'business', seats: 3))
      write = write_subscription(subscription(plan: 'business', seats: 3),
                                 'proration_behavior' => 'always_invoice',
                                 'payment_behavior' => 'pending_if_incomplete',
                                 'items' => [{ 'id' => 'si_seats', 'price' => business_price, 'quantity' => '1' },
                                             { 'price' => fixture_price, 'quantity' => '2' }])

      post '/settings/billing/plan', params: { plan: 'business', price: 'price_forged', quantity: 999 }

      expect(response).to redirect_to('/settings/billing')
      expect(write).to have_been_requested.once
      expect(row.reload).to have_attributes(plan: 'business', quantity: 3)
    end

    it 'switches a Paid trial to Business and grants its 500 included completions' do
      read_subscriptions(subscription(status: 'trialing'), subscription(plan: 'business', status: 'trialing'))
      write_subscription(subscription(plan: 'business', status: 'trialing'),
                         'proration_behavior' => 'none',
                         'items' => [{ 'id' => 'si_seats', 'price' => business_price, 'quantity' => '1' }])

      post '/settings/billing/plan', params: { plan: 'business' }

      expect(row.reload).to have_attributes(plan: 'business', access_state: 'trialing')
      expect(Quotas.limits_for(account.reload).api_completions_per_month).to eq(500)
    end

    it 'allows packs during trial with no charge now and recurring billing at trial end' do
      read_subscriptions(subscription(status: 'trialing'))
      write = write_subscription(subscription(status: 'trialing', packs: 2),
                                 'proration_behavior' => 'none',
                                 'items' => [{ 'price' => pack_price, 'quantity' => '2' }])

      post '/settings/billing/api_packs', params: { quantity: 2 }

      expect(write).to have_been_requested.once
      expect(row.reload.effective_api_pack_quantity).to eq(2)
      expect(ApiPackPurchase.count).to eq(0)
    end

    it 'schedules a one-seat Business downgrade without credit and keeps Business until renewal' do
      row.update!(plan: 'business')
      read_subscriptions(subscription(plan: 'business'))
      write = write_subscription(subscription,
                                 'proration_behavior' => 'none',
                                 'items' => [{ 'id' => 'si_business', 'price' => fixture_price, 'quantity' => '1' }])

      post '/settings/billing/plan', params: { plan: 'paid' }

      expect(write).to have_been_requested.once
      expect(row.reload).to have_attributes(plan: 'paid', quantity: 1, retained_business_until: period_end)
      expect(Plans.key_for(account.reload)).to eq('business')
      expect(Quotas.limits_for(account).api_completions_per_month).to eq(500)
      travel_to(period_end) do
        expect(Plans.key_for(account.reload)).to eq('paid')
        expect(Quotas.limits_for(account).api_completions_per_month).to eq(50)
      end
    end

    it 'deletes a multi-seat Business base only in a no-charge non-pending downgrade' do
      row.update!(plan: 'business', quantity: 3)
      read_subscriptions(subscription(plan: 'business', seats: 3))
      write = write_subscription(subscription(seats: 3),
                                 'proration_behavior' => 'none',
                                 'items' => [{ 'id' => 'si_business', 'deleted' => 'true' },
                                             { 'id' => 'si_seats', 'quantity' => '3' }])

      post '/settings/billing/plan', params: { plan: 'paid' }

      expect(write).to have_been_requested.once
      expect(row.reload.effective_plan).to eq('business')
    end

    it 'cannot earn credit or extra allowance by downgrading then keeping Business' do
      row.update!(plan: 'business')
      read_subscriptions(subscription(plan: 'business'))
      downgrade = write_subscription(subscription,
                                     'proration_behavior' => 'none',
                                     'items' => [{ 'id' => 'si_business', 'price' => fixture_price,
                                                   'quantity' => '1' }])
      restore = write_subscription(subscription(plan: 'business'),
                                   'proration_behavior' => 'none',
                                   'items' => [{ 'id' => 'si_seats', 'price' => business_price, 'quantity' => '1' }])

      post '/settings/billing/plan', params: { plan: 'paid' }
      expect(row.reload.effective_plan).to eq('business')
      post '/settings/billing/plan', params: { plan: 'business' }

      expect(downgrade).to have_been_requested.once
      expect(restore).to have_been_requested.once
      expect(row.reload.retained_business_until).to be_nil
      expect(Quotas.limits_for(account.reload).api_completions_per_month).to eq(500)
    end

    it 'adds packs with a separate FULL $10 per-unit invoice and a no-proration recurring update' do
      read_subscriptions(subscription)
      creation, item, payment = stub_pack_invoice
      write = write_subscription(subscription(packs: 2), 'proration_behavior' => 'none',
                                                         'items' => [{ 'price' => pack_price, 'quantity' => '2' }])

      post '/settings/billing/api_packs', params: { quantity: 2 }

      expect(creation).to have_been_requested.once
      expect(item).to have_been_requested.once
      expect(payment).to have_been_requested.once
      expect(write).to have_been_requested.once
      expect(pack_purchase.amount_cents).to eq(2000)
      expect(pack_purchase.applied_at).to be_present
      expect(row.reload.effective_api_pack_quantity).to eq(2)
      expect(Quotas.limits_for(account.reload).api_completions_per_month).to eq(150)
    end

    it 'does not buy packs twice when the same target is submitted again' do
      read_subscriptions(subscription)
      creation, _item, payment = stub_pack_invoice
      write = write_subscription(subscription(packs: 2), 'proration_behavior' => 'none',
                                                         'items' => [{ 'price' => pack_price, 'quantity' => '2' }])

      2.times { post '/settings/billing/api_packs', params: { quantity: 2, price: 'price_forged' } }

      expect(creation).to have_been_requested.once
      expect(payment).to have_been_requested.once
      expect(write).to have_been_requested.once
      expect(row.reload.api_pack_quantity).to eq(2)
    end

    it 'retains removed packs until renewal, including across repeated syncs' do
      row.update!(api_pack_quantity: 3)
      read_subscriptions(subscription(packs: 3), subscription(packs: 1))
      write = write_subscription(subscription(packs: 1),
                                 'proration_behavior' => 'none',
                                 'items' => { '0' => { 'id' => 'si_packs', 'quantity' => '1' } })

      post '/settings/billing/api_packs', params: { quantity: 1 }
      StripeBilling::SubscriptionSync.apply!(row.reload, subscription(packs: 1))

      expect(write).to have_been_requested.once
      expect(row.reload).to have_attributes(api_pack_quantity: 1, retained_api_pack_quantity: 3,
                                            retained_api_pack_until: period_end)
      expect(row.effective_api_pack_quantity).to eq(3)
      travel_to(period_end) { expect(row.effective_api_pack_quantity).to eq(1) }
    end

    it 'removes all packs without refunding this period' do
      row.update!(api_pack_quantity: 1)
      read_subscriptions(subscription(packs: 1), subscription)
      write = write_subscription(subscription,
                                 'proration_behavior' => 'none',
                                 'items' => { '0' => { 'id' => 'si_packs', 'deleted' => 'true' } })

      post '/settings/billing/api_packs', params: { quantity: 0 }

      expect(write).to have_been_requested.once
      expect(row.reload.api_pack_quantity).to eq(0)
      expect(row.effective_api_pack_quantity).to eq(1)
    end

    it 'does not charge again for retained capacity when restoring packs' do
      row.update!(api_pack_quantity: 1, retained_api_pack_quantity: 3, retained_api_pack_until: period_end)
      read_subscriptions(subscription(packs: 1), subscription(packs: 2))
      write = write_subscription(subscription(packs: 2), 'proration_behavior' => 'none',
                                                         'items' => [{ 'id' => 'si_packs', 'quantity' => '2' }])

      post '/settings/billing/api_packs', params: { quantity: 2 }

      expect(write).to have_been_requested.once
      expect(row.reload.effective_api_pack_quantity).to eq(3)
    end

    it 'charges only capacity beyond retained packs when increasing again' do
      row.update!(api_pack_quantity: 1, retained_api_pack_quantity: 3, retained_api_pack_until: period_end)
      read_subscriptions(subscription(packs: 1), subscription(packs: 4))
      restore = write_subscription(subscription(packs: 3),
                                   'proration_behavior' => 'none',
                                   'items' => { '0' => { 'id' => 'si_packs', 'quantity' => '3' } })
      stub_pack_invoice
      charge = write_subscription(subscription(packs: 4),
                                  'proration_behavior' => 'none',
                                  'items' => { '0' => { 'id' => 'si_packs', 'quantity' => '4' } })

      post '/settings/billing/api_packs', params: { quantity: 4 }

      expect(restore).to have_been_requested.once
      expect(charge).to have_been_requested.once
      expect(row.reload.effective_api_pack_quantity).to eq(4)
      expect(pack_purchase.amount_cents).to eq(1000)
    end

    it 'grants no new capacity on an unpaid full-price invoice' do
      read_subscriptions(subscription)
      stub_pack_invoice(paid: false)

      post '/settings/billing/api_packs', params: { quantity: 2 }

      expect(row.reload.effective_api_pack_quantity).to eq(0)
      expect(pack_purchase.applied_at).to be_nil
      expect(flash[:notice]).to eq(I18n.t('billing_change_pending'))
    end

    it 'keeps Paid active when a Business payment is pending without deleting an item' do
      read_subscriptions(subscription)
      write_subscription(subscription(pending_update: { expires_at: 1.day.from_now.to_i }),
                         'proration_behavior' => 'always_invoice', 'payment_behavior' => 'pending_if_incomplete',
                         'items' => [{ 'id' => 'si_seats', 'price' => business_price, 'quantity' => '1' }])

      post '/settings/billing/plan', params: { plan: 'business' }

      expect(row.reload.plan).to eq('paid')
      expect(flash[:notice]).to eq(I18n.t('billing_change_pending'))
    end

    it 'refuses to overwrite a pending payment or an external subscription schedule' do
      [subscription(pending_update: { expires_at: 1.day.from_now.to_i }), subscription(schedule: 'sub_sched_external')]
        .each do |body|
          read_subscriptions(body)
          post '/settings/billing/api_packs', params: { quantity: 2 }

          expect(response).to redirect_to('/settings/billing')
          expect(flash[:alert]).to be_present
        end
    end

    it 'refuses unavailable products and invalid quantities before contacting Stripe' do
      %w[-1 1.5 10000 banana].each do |quantity|
        post '/settings/billing/api_packs', params: { quantity: }

        expect(flash[:alert]).to eq(I18n.t('billing_api_packs_invalid'))
      end
      ENV.delete('STRIPE_BUSINESS_PRICE_ID')
      post '/settings/billing/plan', params: { plan: 'business' }
      expect(flash[:alert]).to eq(I18n.t('billing_business_unavailable'))
      ENV.delete('STRIPE_API_PACK_PRICE_ID')
      post '/settings/billing/api_packs', params: { quantity: 1 }
      expect(flash[:alert]).to eq(I18n.t('billing_api_packs_unavailable'))
    end

    it 'refuses a child account acting on the billing parent' do
      child = create(:account, linked_account_account: AccountLinkedAccount.new(account_type: :linked, account:))
      sign_out(:user)
      reset!
      sign_in(create(:user, account: child))

      post '/settings/billing/plan', params: { plan: 'business' }
      expect(response).to have_http_status(:not_found)
      post '/settings/billing/api_packs', params: { quantity: 1 }
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses an integration identity at both new billing doors' do
      sign_out(:user)
      reset!
      sign_in(create(:user, account:, role: 'integration'))

      post '/settings/billing/plan', params: { plan: 'business' }
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include('Legacy API integrations cannot access billing settings')
      post '/settings/billing/api_packs', params: { quantity: 1 }
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include('Legacy API integrations cannot access billing settings')
    end
  end

  describe 'full-price invoice recovery' do
    def begin_pending_purchase
      read_subscriptions(subscription)
      stub_pack_invoice(paid: false)
      post '/settings/billing/api_packs', params: { quantity: 2 }
    end

    def deliver_pack_invoice_event(extra = {})
      event = JSON.parse(fixture_body('event-invoice.paid'))
      event['id'] = "evt_#{SecureRandom.hex(8)}"
      event['data']['object'] = pack_invoice('paid').deep_stringify_keys.merge(extra)
      payload = event.to_json
      at = Time.current.to_i
      signature = Stripe::Webhook::Signature.compute_signature(Time.zone.at(at), payload, webhook_secret)
      post '/stripe/webhooks', params: payload,
                               headers: { 'Stripe-Signature' => "t=#{at},v1=#{signature}",
                                          'CONTENT_TYPE' => 'application/json' }
      ProcessStripeEventJob.drain
    end

    it 'verifies the fetched invoice and applies a later paid webhook only once' do
      begin_pending_purchase
      stripe_state[:invoice] = pack_invoice('paid')
      write = write_subscription(subscription(packs: 2), 'proration_behavior' => 'none',
                                                         'items' => [{ 'price' => pack_price, 'quantity' => '2' }])

      2.times { deliver_pack_invoice_event }

      expect(write).to have_been_requested.once
      expect(row.reload.api_pack_quantity).to eq(2)
      expect(pack_purchase.applied_at).to be_present
      expect(StripeEventInbox.order(:id).last).to have_attributes(status: 'processed', account_id: account.id)
    end

    it 'attributes and scrubs a late pack invoice webhook after the account is purged' do
      begin_pending_purchase
      stripe_state[:subscription] = subscription(status: 'canceled')
      stripe_state[:invoice] = pack_invoice('paid')
      row.update!(access_state: 'cancelled', status: 'canceled', stripe_status: 'canceled')
      account.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago)
      expect(Accounts::Purge.call(account)).to eq(:purged)
      allow(OperatorAlert).to receive(:deliver)

      deliver_pack_invoice_event('customer_email' => 'former-customer@example.com',
                                 'hosted_invoice_url' => 'https://invoice.stripe.com/private-customer-link')

      inbox = StripeEventInbox.order(:id).last
      expect(inbox).to have_attributes(status: 'processed', account_id: account.id)
      expect(inbox.event_object).to include('customer_email' => '[redacted]', 'hosted_invoice_url' => '[redacted]')
      expect(inbox.payload).not_to include('former-customer@example.com', 'private-customer-link')
      expect(pack_purchase).to have_attributes(paid_at: be_present, closed_at: be_present, applied_at: nil)
      expect(row.reload.api_pack_quantity).to eq(0)
    end

    it 'does not grant packs merely because a stale event claims the invoice is paid' do
      begin_pending_purchase

      deliver_pack_invoice_event

      expect(row.reload.api_pack_quantity).to eq(0)
      expect(pack_purchase.applied_at).to be_nil
    end

    it 'recovers a paid invoice and successful remote update after the local sync rolls back' do
      read_subscriptions(subscription)
      creation, _item, payment = stub_pack_invoice
      write = write_subscription(subscription(packs: 2), 'proration_behavior' => 'none',
                                                         'items' => [{ 'price' => pack_price, 'quantity' => '2' }])
      allow(StripeBilling::SubscriptionSync).to receive(:apply!).and_wrap_original do |original, local_row, remote|
        if StripeBilling::SubscriptionSync.field(StripeBilling::TierChanges.pack_item(remote), :quantity).to_i == 2
          raise ActiveRecord::StatementInvalid, 'simulated local write failure after Stripe applied the purchase'
        end

        original.call(local_row, remote)
      end

      expect { post '/settings/billing/api_packs', params: { quantity: 2 } }
        .to raise_error(ActiveRecord::StatementInvalid, /simulated local write failure/)
      expect(ApiPackPurchase.open.count).to eq(1)
      operation_key = pack_purchase.operation_key
      allow(StripeBilling::SubscriptionSync).to receive(:apply!).and_call_original
      reset!
      sign_in(User.find(admin.id))

      post '/settings/billing/api_packs', params: { quantity: 2 }

      expect(creation).to have_been_requested.once
      expect(payment).to have_been_requested.once
      expect(write).to have_been_requested.once
      expect(pack_purchase.operation_key).to eq(operation_key)
      expect(pack_purchase.applied_at).to be_present
      expect(row.reload.api_pack_quantity).to eq(2)
    end

    it 'lets reconciliation recover a paid invoice without attempting another payment' do
      begin_pending_purchase
      stripe_state[:invoice] = pack_invoice('paid')
      write = write_subscription(subscription(packs: 2), 'proration_behavior' => 'none',
                                                         'items' => [{ 'price' => pack_price, 'quantity' => '2' }])

      StripeBilling::PackPurchases.reconcile!

      expect(write).to have_been_requested.once
      expect(pack_purchase.applied_at).to be_present
      expect(a_request(:post, 'https://api.stripe.com/v1/invoices/in_api_packs/pay')).to have_been_made.once
    end

    it 'refuses an invoice with the wrong customer or full amount' do
      begin_pending_purchase
      stripe_state[:invoice] = pack_invoice('paid').merge(total: 1)

      expect { StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false) }
        .to raise_error(StripeBilling::TierChanges::Unavailable)
      stripe_state[:invoice] = pack_invoice('paid').merge(customer: 'cus_someone_else')
      expect { StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false) }
        .to raise_error(StripeBilling::TierChanges::Unavailable)
      expect(row.reload.api_pack_quantity).to eq(0)
    end

    it 'never creates another invoice after idempotency retention may have expired' do
      begin_pending_purchase
      pack_purchase.update!(stripe_invoice_id: nil, created_at: 2.days.ago)
      stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/invoices/search})
        .to_return(**stripe_json(object: 'search_result', data: []))

      expect { StripeBilling::PackPurchases.process!(pack_purchase) }
        .to raise_error(StripeBilling::TierChanges::Unavailable)
      expect(a_request(:post, 'https://api.stripe.com/v1/invoices')).to have_been_made.once
      expect(ApiPackPurchase.open.count).to eq(1)
    end

    it 'voids an unpaid invoice when its subscription is cancelled' do
      begin_pending_purchase
      stripe_state[:subscription] = subscription(status: 'canceled')
      void = stub_request(:post, 'https://api.stripe.com/v1/invoices/in_api_packs/void')
             .with(body: {}).to_return(**stripe_json(pack_invoice('void')))

      expect(StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false)).to eq(:expired)
      expect(void).to have_been_requested.once
      expect(pack_purchase.closed_at).to be_present
      expect(pack_purchase.paid_at).to be_nil
    end

    it 'keeps a cancelled purchase recoverable while invoice search has not caught up' do
      begin_pending_purchase
      pack_purchase.update!(stripe_invoice_id: nil)
      stripe_state[:subscription] = subscription(status: 'canceled')
      search = stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/invoices/search})
               .to_return(**stripe_json(object: 'search_result', data: []))
      allow(OperatorAlert).to receive(:deliver)

      expect(StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false)).to eq(:review)
      expect(pack_purchase.closed_at).to be_nil
      expect(ApiPackPurchase.open.count).to eq(1)
      expect(OperatorAlert).to have_received(:deliver).with(
        subject: 'API pack invoice recovery needs operator review', body: include(pack_purchase.operation_key)
      )
      remove_request_stub(search)
      void = stub_request(:post, 'https://api.stripe.com/v1/invoices/in_api_packs/void')
             .with(body: {}).to_return(**stripe_json(pack_invoice('void')))

      expect(StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false)).to eq(:expired)
      expect(void).to have_been_requested.once
      expect(pack_purchase.closed_at).to be_present
      expect(a_request(:post, 'https://api.stripe.com/v1/invoices')).to have_been_made.once
    end

    it 'recovers draft expiry after Stripe voids the invoice but its response is lost' do
      begin_pending_purchase
      stripe_state[:invoice] = pack_invoice('draft')
      pack_purchase.update!(expires_at: 1.minute.ago)
      void = stub_request(:post, 'https://api.stripe.com/v1/invoices/in_api_packs/void').with(body: {})
      void.to_return do
        stripe_state[:invoice] = pack_invoice('void')
        raise Net::ReadTimeout, 'simulated lost void response'
      end

      expect { StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false) }
        .to raise_error(Stripe::APIConnectionError)
      expect(pack_purchase.closed_at).to be_nil
      expect(StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false)).to eq(:expired)
      expect(pack_purchase.closed_at).to be_present
      expect(void).to have_been_requested.times(StripeBilling::MAX_NETWORK_RETRIES + 1)
      expect(a_request(:delete, 'https://api.stripe.com/v1/invoices/in_api_packs')).not_to have_been_made
      expect(a_request(:post, 'https://api.stripe.com/v1/invoices/in_api_packs/pay')).to have_been_made.once
      expect(row.reload.api_pack_quantity).to eq(0)
    end

    it 'records and alerts a paid invoice that cannot be fulfilled after cancellation' do
      begin_pending_purchase
      stripe_state[:subscription] = subscription(status: 'canceled')
      stripe_state[:invoice] = pack_invoice('paid')
      allow(OperatorAlert).to receive(:deliver)

      expect(StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false)).to eq(:review)
      expect(pack_purchase.paid_at).to be_present
      expect(pack_purchase.applied_at).to be_nil
      expect(pack_purchase.closed_at).to be_present
      expect(OperatorAlert).to have_received(:deliver).with(
        subject: 'Paid API packs need operator review', body: include('in_api_packs', '2000 cents')
      )
    end

    it 'expires an unpaid purchase without changing recurring quantity' do
      begin_pending_purchase
      pack_purchase.update!(expires_at: 1.minute.ago)
      void = stub_request(:post, 'https://api.stripe.com/v1/invoices/in_api_packs/void')
             .with(body: {}).to_return(**stripe_json(pack_invoice('void')))

      StripeBilling::PackPurchases.reconcile!

      expect(void).to have_been_requested.once
      expect(pack_purchase.closed_at).to be_present
      expect(row.reload.api_pack_quantity).to eq(0)
    end

    it 'does not revive removed capacity for free when a payment crosses renewal' do
      row.update!(api_pack_quantity: 1, retained_api_pack_quantity: 3, retained_api_pack_until: period_end)
      read_subscriptions(subscription(packs: 1))
      stub_pack_invoice(paid: false)
      restore = write_subscription(subscription(packs: 3), 'proration_behavior' => 'none',
                                                           'items' => [{ 'id' => 'si_packs', 'quantity' => '3' }])
      post '/settings/billing/api_packs', params: { quantity: 4 }
      expect(restore).to have_been_requested.once
      expect(row.reload.api_pack_quantity).to eq(3)
      expect(pack_purchase.amount_cents).to eq(1000)

      travel_to(period_end) do
        stripe_state[:invoice] = pack_invoice('paid')
        write = write_subscription(subscription(packs: 4), 'proration_behavior' => 'none',
                                                           'items' => [{ 'id' => 'si_packs', 'quantity' => '4' }])
        StripeBilling::PackPurchases.process!(pack_purchase, attempt_payment: false)

        expect(write).to have_been_requested.once
        expect(row.reload.api_pack_quantity).to eq(4)
      end
    end
  end

  describe 'operator API agreements' do
    [0, 750, -1].each do |override|
      it "refuses plan and pack changes before Stripe for override #{override}" do
        AccountLimitOverride.create!(account:, api_completions_per_month: override)

        post '/settings/billing/plan', params: { plan: 'business' }
        expect(flash[:alert]).to eq(I18n.t('billing_capacity_by_agreement'))
        post '/settings/billing/api_packs', params: { quantity: 2 }
        expect(flash[:alert]).to eq(I18n.t('billing_capacity_by_agreement'))
        expect(ApiPackPurchase.count).to eq(0)
      end
    end
  end

  describe 'Business seat changes' do
    before { row.update!(plan: 'business', stripe_item_id: 'si_business', stripe_price_id: business_price) }

    it 'adds the second seat on the seat price without changing the Business base' do
      read_subscriptions(subscription(plan: 'business'))
      at = Time.current.to_i
      write = write_subscription(subscription(plan: 'business', seats: 2),
                                 'proration_behavior' => 'always_invoice', 'proration_date' => at.to_s,
                                 'payment_behavior' => 'pending_if_incomplete',
                                 'items' => { '0' => { 'price' => fixture_price, 'quantity' => '1' } })

      BillingLifecycle.add_seat!(row, quantity_after: 2, idempotency_key: 'business-seat',
                                      proration_date: at)

      expect(write).to have_been_requested.once
    end

    it 'releases the final extra seat by deleting only that item' do
      row.update!(quantity: 2)
      read_subscriptions(subscription(plan: 'business', seats: 2), subscription(plan: 'business'))
      write = write_subscription(subscription(plan: 'business'),
                                 'proration_behavior' => 'none',
                                 'items' => { '0' => { 'id' => 'si_seats', 'deleted' => 'true' } })

      expect(BillingLifecycle.release_seats!(row)).to eq(:updated)
      expect(write).to have_been_requested.once
      expect(row.reload).to have_attributes(plan: 'business', quantity: 1, stripe_item_id: 'si_business')
    end
  end
end
