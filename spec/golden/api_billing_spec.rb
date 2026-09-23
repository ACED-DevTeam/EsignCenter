# frozen_string_literal: true

# D79 uses the same captured Stripe subscriptions as the original billing
# suite. Only the items and dates are changed to represent the new products;
# WebMock refuses any request not explicitly answered here.
RSpec.describe 'API plan billing', type: :request do
  include_context 'with a Stripe test account'

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
    stub_request(:get, seat_subscription_url(subscription_a))
      .with(query: hash_including('expand' => StripeBilling::SUBSCRIPTION_EXPAND))
      .to_return(*bodies.map { |body| stripe_json(body) })
  end

  def write_subscription(body, expected)
    expected['items'] = expected['items'].values if expected['items'].is_a?(Hash)

    stub_request(:post, seat_subscription_url(subscription_a))
      .with(body: hash_including(expected))
      .to_return(**stripe_json(body))
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
                                 'items' => { '0' => { 'price' => business_price, 'quantity' => '1' },
                                              '1' => { 'id' => 'si_seats', 'quantity' => '2' } })

      post '/settings/billing/plan', params: { plan: 'business', price: 'price_forged', quantity: 999 }

      expect(response).to redirect_to('/settings/billing')
      expect(write).to have_been_requested.once
      expect(row.reload).to have_attributes(plan: 'business', quantity: 3)
    end

    it 'switches a Paid trial to Business and grants its 500 included completions' do
      read_subscriptions(subscription(status: 'trialing'), subscription(plan: 'business', status: 'trialing'))
      write_subscription(subscription(plan: 'business', status: 'trialing'), 'proration_behavior' => 'always_invoice')

      post '/settings/billing/plan', params: { plan: 'business' }

      expect(row.reload).to have_attributes(plan: 'business', access_state: 'trialing')
      expect(Quotas.limits_for(account.reload).api_completions_per_month).to eq(500)
    end

    it 'refuses packs during trial because their remainder cannot be invoiced immediately' do
      read_subscriptions(subscription(status: 'trialing'))

      post '/settings/billing/api_packs', params: { quantity: 2 }

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:alert]).to eq(I18n.t('billing_api_packs_trial'))
      expect(row.reload.effective_api_pack_quantity).to eq(0)
    end

    it 'switches Business to Paid, deleting its base and restoring the included seat' do
      row.update!(plan: 'business')
      read_subscriptions(subscription(plan: 'business'), subscription)
      write = write_subscription(subscription,
                                 'proration_behavior' => 'always_invoice',
                                 'items' => { '0' => { 'id' => 'si_business', 'deleted' => 'true' },
                                              '1' => { 'price' => fixture_price, 'quantity' => '1' } })

      post '/settings/billing/plan', params: { plan: 'paid' }

      expect(write).to have_been_requested.once
      expect(row.reload).to have_attributes(plan: 'paid', quantity: 1)
    end

    it 'adds packs with an immediate prorated invoice and applies Stripe-confirmed capacity' do
      read_subscriptions(subscription, subscription(packs: 2))
      write = write_subscription(subscription(packs: 2),
                                 'proration_behavior' => 'always_invoice',
                                 'payment_behavior' => 'pending_if_incomplete',
                                 'items' => { '0' => { 'price' => pack_price, 'quantity' => '2' } })

      post '/settings/billing/api_packs', params: { quantity: 2 }

      expect(write).to have_been_requested.once
      expect(row.reload.effective_api_pack_quantity).to eq(2)
      expect(Quotas.limits_for(account.reload).api_completions_per_month).to eq(150)
    end

    it 'does not buy packs twice when the same target is submitted again' do
      read_subscriptions(subscription, subscription(packs: 2))
      write = write_subscription(subscription(packs: 2), 'proration_behavior' => 'always_invoice')

      2.times { post '/settings/billing/api_packs', params: { quantity: 2, price: 'price_forged' } }

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
      write = write_subscription(subscription(packs: 2), 'proration_behavior' => 'none')

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
      charge = write_subscription(subscription(packs: 4),
                                  'proration_behavior' => 'always_invoice',
                                  'items' => { '0' => { 'id' => 'si_packs', 'quantity' => '4' } })

      post '/settings/billing/api_packs', params: { quantity: 4 }

      expect(restore).to have_been_requested.once
      expect(charge).to have_been_requested.once
      expect(row.reload.effective_api_pack_quantity).to eq(4)
    end

    it 'grants no capacity on a pending payment' do
      read_subscriptions(subscription)
      write_subscription(subscription(pending_update: { expires_at: 1.day.from_now.to_i }),
                         'proration_behavior' => 'always_invoice')

      post '/settings/billing/api_packs', params: { quantity: 2 }

      expect(row.reload.effective_api_pack_quantity).to eq(0)
      expect(flash[:notice]).to eq(I18n.t('billing_change_pending'))
    end

    it 'keeps Paid active when a Business payment is pending' do
      read_subscriptions(subscription)
      write_subscription(subscription(pending_update: { expires_at: 1.day.from_now.to_i }),
                         'proration_behavior' => 'always_invoice')

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

  describe 'Business seat changes' do
    before { row.update!(plan: 'business', stripe_item_id: 'si_business', stripe_price_id: business_price) }

    it 'adds the second seat on the seat price without changing the Business base' do
      read_subscriptions(subscription(plan: 'business'))
      write = write_subscription(subscription(plan: 'business', seats: 2),
                                 'items' => { '0' => { 'price' => fixture_price, 'quantity' => '1' } })

      BillingLifecycle.add_seat!(row, quantity_after: 2, idempotency_key: 'business-seat',
                                      proration_date: Time.current.to_i)

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
