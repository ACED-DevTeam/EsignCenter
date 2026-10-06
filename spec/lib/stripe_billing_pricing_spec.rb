# frozen_string_literal: true

RSpec.describe StripeBilling do
  it 'keeps the approved catalog amounts exact for Stripe' do
    expect(StripeBilling::PriceGuard.expectation(:seat)[:amount]).to eq(999)
    expect(StripeBilling::PriceGuard.expectation(:business)[:amount]).to eq(4999)
    expect(StripeBilling::PriceGuard.expectation(:api_pack)[:amount]).to eq(999)
    expect(PricingMatrix.price_per_seat).to eq(9.99)
    expect(PricingMatrix.business_price).to eq(49.99)
    expect(PricingMatrix.api_pack_price).to eq(9.99)
  end

  it 'calculates a large pack purchase entirely in integer cents' do
    purchase = ApiPackPurchase.new(added_quantity: 101)

    expect(purchase.amount_cents).to eq(100_899)
    expect(purchase.amount_cents).to be_an(Integer)
  end

  it 'adds Business, extra seats and packs without floating-point accumulation' do
    subscription = AccountSubscription.new(plan: 'business', quantity: 100, api_pack_quantity: 100)

    expect(subscription.monthly_amount_cents).to eq(203_800)
    expect(subscription.monthly_amount_cents).to be_an(Integer)
    expect(subscription.monthly_amount_usd).to eq(2038)
  end

  it 'uses the seat amount for every Paid seat and only current recurring packs' do
    subscription = AccountSubscription.new(plan: 'paid', quantity: 3, api_pack_quantity: 2,
                                           retained_api_pack_quantity: 10, retained_api_pack_until: 1.day.from_now)

    expect(subscription.monthly_amount_cents).to eq(4995)
    expect(subscription.monthly_amount_usd).to eq(49.95)
  end
end
