# frozen_string_literal: true

# The billing page in a real browser: the settings nav offers it, the two plan
# cards render, and the state a subscription is in is the first thing read.
# The buttons themselves lead to stripe.com, so they are proven at the request
# level (spec/golden/billing_page_spec.rb) rather than clicked here.
RSpec.describe 'Billing settings' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  around do |example|
    original = ENV.fetch('BILLING_ENABLED', nil)
    ENV['BILLING_ENABLED'] = 'true'

    example.run
  ensure
    original.nil? ? ENV.delete('BILLING_ENABLED') : ENV['BILLING_ENABLED'] = original
  end

  before { sign_in(user) }

  it 'is reachable from the settings nav and offers the free and paid plans' do
    visit settings_usage_path

    click_link I18n.t('billing')

    expect(page).to have_current_path(settings_billing_path)
    expect(page).to have_content(I18n.t('billing_state_free'))
    expect(page).to have_content(I18n.t('billing_free_limit_completions', count: 5))
    expect(page).to have_content(I18n.t('billing_paid_plan_price', price: StripeBilling::PRICE_PER_SEAT_USD,
                                                                   trial_days: StripeBilling::TRIAL_PERIOD_DAYS))
    expect(page).to have_button(I18n.t('start_free_trial', trial_days: StripeBilling::TRIAL_PERIOD_DAYS))
    expect(page).to have_link(I18n.t('billing_view_usage'), href: settings_usage_path)
  end

  it 'leads with the trial end date and the portal button once a trial is running' do
    create(:account_subscription, account:, access_state: 'trialing', status: 'trialing',
                                  stripe_customer_id: 'cus_x', stripe_subscription_id: 'sub_x',
                                  trial_end: 10.days.from_now, current_period_end: 10.days.from_now,
                                  trial_used_at: Time.current)

    visit settings_billing_path

    expect(page).to have_content(
      I18n.t('billing_trial_ends_on', date: I18n.l(10.days.from_now.to_date, format: :long))
    )
    expect(page).to have_button(I18n.t('manage_billing'))
    expect(page).to have_no_button(I18n.t('start_free_trial', trial_days: StripeBilling::TRIAL_PERIOD_DAYS))
  end
end
