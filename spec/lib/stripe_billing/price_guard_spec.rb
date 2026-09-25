# frozen_string_literal: true

# A test-mode price under a live key boots fine and then fails every Checkout
# with Stripe's "No such price". The guard catches that — and an archived,
# re-priced or wrong-interval price — at the moment of the sale, tells the
# operator, and never asks Stripe at boot.
RSpec.describe StripeBilling::PriceGuard do
  include_context 'with a Stripe test account'

  stash_env(*StripeBilling::OPTIONAL_CONFIG_KEYS, clear: true)

  before do
    allow(ErrorReport).to receive(:error)
    allow(OperatorAlert).to receive(:deliver)
  end

  def stub_seat_price(**overrides)
    stub_request(:get, "https://api.stripe.com/v1/prices/#{fixture_price}")
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: stripe_price_body(fixture_price, unit_amount: 1000, **overrides).to_json)
  end

  it 'passes the price the app sells, in the key\'s own mode' do
    expect(described_class.verify!(:seat)).to be(true)
    expect(ErrorReport).not_to have_received(:error)
  end

  it 'refuses a test-mode price under a live key, and alerts the operator without naming the key' do
    ENV['STRIPE_SECRET_KEY'] = 'sk_live_realsecretvalue'

    expect { described_class.verify!(:seat) }
      .to raise_error(described_class::Misconfigured, /STRIPE_PRICE_ID .*livemode=false does not match the live/)
    expect(ErrorReport).to have_received(:error)
      .with(/Stripe price refused at checkout: STRIPE_PRICE_ID/, price_env: 'STRIPE_PRICE_ID')
    expect(OperatorAlert).to have_received(:deliver)
      .with(subject: 'Stripe price misconfigured — purchases refused', body: satisfy { |body|
        body.include?(fixture_price) && body.exclude?('realsecretvalue')
      })
  end

  it 'refuses a price the configured key cannot find (the other mode or another account)' do
    stub_request(:get, "https://api.stripe.com/v1/prices/#{fixture_price}")
      .to_return(stripe_price_missing(fixture_price))

    expect { described_class.verify!(:seat) }
      .to raise_error(described_class::Misconfigured, /was not found with the configured test secret key/)
  end

  it 'names every way a price is the wrong thing to sell' do
    stub_seat_price(active: false, currency: 'eur', unit_amount: 1500,
                    recurring: { interval: 'year', interval_count: 1 })

    expect { described_class.verify!(:seat) }.to raise_error(described_class::Misconfigured) { |error|
      expect(error.message).to include('is not active', 'currency "eur"', 'amount 1500 (expected 1000)',
                                       'interval 1 "year" (expected 1 month)')
    }
  end

  it 'holds Business and the API pack to their own amounts' do
    ENV['STRIPE_BUSINESS_PRICE_ID'] = 'price_business'
    ENV['STRIPE_API_PACK_PRICE_ID'] = 'price_pack'

    expect(described_class.verify!(:business)).to be(true)
    expect(described_class.verify!(:api_pack)).to be(true)

    stub_request(:get, 'https://api.stripe.com/v1/prices/price_business')
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: stripe_price_body('price_business', unit_amount: 1000).to_json)

    expect { described_class.verify!(:business) }
      .to raise_error(described_class::Misconfigured, /STRIPE_BUSINESS_PRICE_ID .*amount 1000 \(expected 4900\)/)
  end

  it 'lets a Stripe outage surface as its own error rather than as a misconfiguration' do
    stub_request(:get, "https://api.stripe.com/v1/prices/#{fixture_price}").to_timeout

    expect { described_class.verify!(:seat) }.to raise_error(Stripe::APIConnectionError)
    expect(OperatorAlert).not_to have_received(:deliver)
  end

  it 'remembers a good answer and alerts about a bad one at most once an hour' do
    memory = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory)

    described_class.verify!(:seat)
    described_class.verify!(:seat)

    expect(WebMock).to have_requested(:get, "https://api.stripe.com/v1/prices/#{fixture_price}").once

    memory.clear
    stub_seat_price(active: false)
    2.times { expect { described_class.verify!(:seat) }.to raise_error(described_class::Misconfigured) }

    expect(OperatorAlert).to have_received(:deliver).once
  end
end
