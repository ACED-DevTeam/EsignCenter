# frozen_string_literal: true

# The automatic-renewal acknowledgment (BillingMailer#subscription_started,
# docs/legal.md): the email that writes down what the customer agreed to at
# Checkout — price, when the card is charged, that it renews until they
# cancel, and how to cancel. Sent once per Stripe subscription, on the START
# and never again: not on a repeat of the same object, not when the trial
# turns into a charge, and never to a subscriber who was already live before
# this mail existed. Driven through the one mapping every Stripe door shares,
# with real CLI captures (spec/fixtures/stripe).
RSpec.describe 'Subscription started mail', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:) }
  let(:deliveries) { ActionMailer::Base.deliveries }
  let(:fixture_price) { 'price_1UAt8N4rEeOqtLcX1amJxYdZ' }
  let(:trial_subject) { 'Your EsignCenter free trial has started' }
  let(:paid_subject) { 'Your EsignCenter subscription has started' }

  stash_env('STRIPE_PRICE_ID')

  before do
    ENV['STRIPE_PRICE_ID'] = fixture_price
    deliveries.clear
  end

  # The row a Checkout leaves behind before Stripe has said anything: a
  # customer id, no subscription, access `cancelled`.
  def checkout_row(customer:)
    create(:account_subscription, account:, access_state: 'cancelled', status: 'none', stripe_customer_id: customer)
  end

  def apply!(row, fixture, status: nil)
    body = JSON.parse(Rails.root.join("spec/fixtures/stripe/#{fixture}.json").read)
    body['status'] = status if status

    StripeBilling::SubscriptionSync.apply!(row, body)

    row.reload
  end

  def mails_titled(subject)
    deliveries.select { |mail| mail.subject.to_s == subject }
  end

  def body_of(mail)
    (mail.html_part || mail.text_part || mail.body).decoded
  end

  it 'acknowledges a new trial once, with the price, the first charge date and how to cancel', sidekiq: :inline do
    row = apply!(checkout_row(customer: 'cus_VBqHCUoJle1zGV'), 'subscription-trialing')

    expect(row.access_state).to eq('trialing')

    mail = mails_titled(trial_subject).sole
    body = body_of(mail)
    trial_end = row.trial_end.utc.strftime('%-d %B %Y')
    total = row.quantity * StripeBilling::PRICE_PER_SEAT_USD

    expect(mail.to).to eq([admin.email])
    expect(body).to include("Paid, #{row.quantity} users")
    expect(body).to include("$#{total} per month ($#{StripeBilling::PRICE_PER_SEAT_USD} per user)")
    expect(body).to include("When it ends on #{trial_end}, your card is charged $#{total}")
    expect(body).to include('every month until you cancel')
    expect(body).to include('Settings → Billing').and include('Cancel subscription')
    expect(body).to include("Cancel before #{trial_end} and the plan costs you nothing")
    expect(body).to include('no prorated refunds')
    expect(body).to include('/settings/billing').and include('/terms')

    # The webhook and the Checkout return both apply the same subscription.
    apply!(row, 'subscription-trialing')

    expect(mails_titled(trial_subject).size).to eq(1)
  end

  it 'acknowledges a subscription that starts without a trial, with the renewal date', sidekiq: :inline do
    row = apply!(checkout_row(customer: 'cus_VBqHCUoJle1zGV'), 'subscription-active')

    expect(row.access_state).to eq('active')

    body = body_of(mails_titled(paid_subject).sole)

    expect(body).to include('your card has been charged for the first month')
    expect(body).to include("again on #{row.current_period_end.utc.strftime('%-d %B %Y')}")
    expect(body).to include('every month until you cancel')
    expect(mails_titled(trial_subject)).to be_empty
  end

  it 'says nothing when a running trial turns into a charge', sidekiq: :inline do
    row = apply!(checkout_row(customer: 'cus_VBqHCUoJle1zGV'), 'subscription-trialing')
    deliveries.clear

    apply!(row, 'subscription-active')

    expect(row.access_state).to eq('active')
    expect(mails_titled(paid_subject)).to be_empty
    expect(mails_titled(trial_subject)).to be_empty
  end

  # Subscribers who were live before this mail shipped: the nightly sweep
  # re-applies their subscription, and that is not a start.
  it 'never mails a subscription that was already live', sidekiq: :inline do
    row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                        stripe_customer_id: 'cus_VBqHCUoJle1zGV',
                                        stripe_subscription_id: 'sub_1UBSbL4rEeOqtLcXAD6ynIIK')

    apply!(row, 'subscription-active')
    apply!(row, 'subscription-trialing')

    expect(mails_titled(paid_subject)).to be_empty
    expect(mails_titled(trial_subject)).to be_empty
  end

  it 'does not fail the apply when the mail cannot be queued' do
    row = checkout_row(customer: 'cus_VBqHCUoJle1zGV')
    broken = instance_double(ActionMailer::MessageDelivery)
    allow(broken).to receive(:deliver_later!).and_raise('the mail queue is down')
    allow(BillingMailer).to receive(:subscription_started).and_return(broken)
    allow(ErrorReport).to receive(:error)

    expect { apply!(row, 'subscription-trialing') }.not_to raise_error

    expect(row.access_state).to eq('trialing')
    expect(ErrorReport).to have_received(:error)
  end
end
