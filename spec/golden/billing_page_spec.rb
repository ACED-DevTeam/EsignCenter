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
RSpec.describe 'Billing page', type: :request do
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

  def stub_checkout_create
    stub_request(:post, 'https://api.stripe.com/v1/checkout/sessions')
      .to_return(**stripe_json(id: 'cs_test_fixture', object: 'checkout.session', url: checkout_url))
  end

  def stub_portal_create
    stub_request(:post, 'https://api.stripe.com/v1/billing_portal/sessions')
      .to_return(**stripe_json(id: 'bps_test_fixture', object: 'billing_portal.session', url: portal_url))
  end

  def trialing_subscription
    JSON.parse(Rails.root.join('spec/fixtures/stripe/subscription-trialing.json').read)
  end

  def stub_checkout_retrieve(session_id, reference:, subscription: trialing_subscription)
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/checkout/sessions/#{session_id}})
      .to_return(**stripe_json(id: session_id, object: 'checkout.session', mode: 'subscription',
                               client_reference_id: reference, customer: subscription['customer'],
                               subscription:))
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
      expect(free_card.text).to include(I18n.t('billing_free_limit_storage', size: '1 GB'))

      paid_card = doc.at('[data-billing-card="paid"]')
      expect(paid_card.text).to include(I18n.t('billing_paid_plan_price'))
      expect(paid_card.text).to include(I18n.t('billing_benefit_api'))
      expect(paid_card.text).to include(I18n.t('billing_seats_billed', count: 1))
      expect(paid_card.at('[data-billing-checkout-button]').text.strip).to eq(I18n.t('start_free_trial'))
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
      expect(customer.dig('metadata', 'account_id')).to eq(account.id.to_s)
      expect(customer['email']).to eq(admin_for(account).email)

      session = posted('https://api.stripe.com/v1/checkout/sessions')
      expect(session['mode']).to eq('subscription')
      expect(session['client_reference_id']).to eq(account.id.to_s)
      expect(session.dig('line_items', '0', 'price')).to eq(price_id)
      expect(session.dig('line_items', '0', 'quantity')).to eq('2')
      expect(session.dig('subscription_data', 'trial_period_days')).to eq('14')
      expect(session.dig('subscription_data', 'trial_settings', 'end_behavior',
                         'missing_payment_method')).to eq('cancel')
      expect(session.dig('subscription_data', 'metadata', 'account_id')).to eq(account.id.to_s)
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

      expect(doc.at('[data-billing-banner="suspended"]').text).to include(I18n.t('billing_suspended_banner'))
      expect(doc.at('[data-billing-portal-button]')).to be_present
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

    it 'offers nothing to buy or manage on a plan the operator granted by hand' do
      create(:account_subscription, account:, access_state: 'active', status: 'manual')

      doc = page

      expect(doc.at('[data-billing-state]')['data-billing-state']).to eq('manual')
      expect(doc.at('[data-billing-card="manual"]').text).to include(I18n.t('billing_managed_by_operator'))
      expect(doc.at('[data-billing-checkout-button]')).to be_nil
      expect(doc.at('[data-billing-portal-button]')).to be_nil
    end
  end

  describe 'coming back from Checkout' do
    before { act_as(admin_for(account)) }

    it 'links the subscription so the page tells the truth before the webhook lands' do
      stub_checkout_retrieve('cs_test_ok', reference: account.id.to_s)

      get '/settings/billing/return', params: { session_id: 'cs_test_ok' }

      expect(response).to redirect_to('/settings/billing')
      expect(flash[:notice]).to eq(I18n.t('billing_trial_started'))

      subscription = account.reload.account_subscription
      expect(subscription.access_state).to eq('trialing')
      expect(subscription.stripe_subscription_id).to eq(trialing_subscription['id'])
      expect(subscription.quantity).to eq(3)
      expect(subscription.trial_used_at).to be_present
      expect(Plans.key_for(account)).to eq(Plans::PAID)

      expect(page.at('[data-billing-state]')['data-billing-state']).to eq('trialing')
    end

    it 'ignores a Checkout session that belongs to somebody else' do
      other = create(:account)
      stub_checkout_retrieve('cs_test_other', reference: other.id.to_s)

      get '/settings/billing/return', params: { session_id: 'cs_test_other' }

      expect(account.reload.account_subscription).to be_nil
      expect(Plans.key_for(account)).to eq(Plans::FREE)
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
