# frozen_string_literal: true

# Every sale asks Stripe about the price it is about to use
# (StripeBilling::PriceGuard). By default each configured price answers as the
# healthy test-mode object the app expects, read from the env at request time
# so an example's own STRIPE_*_PRICE_ID wins; any other id is Stripe's 404.
# An example about a broken price stubs it again — the later stub wins.
module StripePriceStubs
  def stub_sellable_prices
    stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/prices/[^/?]+}).to_return do |request|
      id = request.uri.path.split('/').last
      role = { StripeBilling.price_id => :seat, StripeBilling.business_price_id => :business,
               StripeBilling.api_pack_price_id => :api_pack }[id]

      next stripe_price_missing(id) unless role

      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: stripe_price_body(id, unit_amount: StripeBilling::PriceGuard.expectation(role)[:amount]).to_json }
    end
  end

  def stripe_price_body(id, unit_amount:, **overrides)
    { id:, object: 'price', livemode: false, active: true, currency: 'usd', unit_amount:, type: 'recurring',
      recurring: { interval: 'month', interval_count: 1, usage_type: 'licensed' } }.merge(overrides)
  end

  def stripe_price_missing(id)
    { status: 404, headers: { 'Content-Type' => 'application/json' },
      body: { error: { type: 'invalid_request_error', code: 'resource_missing', param: 'price',
                       message: "No such price: '#{id}'" } }.to_json }
  end
end

RSpec.configure do |config|
  config.include StripePriceStubs
  config.before { stub_sellable_prices }
end
