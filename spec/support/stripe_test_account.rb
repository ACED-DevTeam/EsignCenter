# frozen_string_literal: true

# The two fixture actors, the credentials every example runs against and the
# reader for the captures — shared by both top-level groups below, so a
# fixture id or a key can never drift between them.
RSpec.shared_context 'with a Stripe test account' do
  let(:subscription_a) { 'sub_1UBSbL4rEeOqtLcXAD6ynIIK' }
  let(:customer_a) { 'cus_VBqHCUoJle1zGV' }
  let(:subscription_b) { 'sub_1UBSds4rEeOqtLcXs81X4tCG' }
  let(:customer_b) { 'cus_VBqKHh0NHYmvT1' }
  let(:webhook_secret) { 'whsec_testsecret' }
  let(:fixture_price) { 'price_1UAt8N4rEeOqtLcX1amJxYdZ' }

  stash_env(*StripeBilling::CONFIG_KEYS.keys, 'BILLING_ENABLED')

  before do
    ENV['STRIPE_SECRET_KEY'] = 'sk_test_fake'
    ENV['STRIPE_PUBLISHABLE_KEY'] = 'pk_test_fake'
    ENV['STRIPE_WEBHOOK_SECRET'] = webhook_secret
    ENV['STRIPE_PRICE_ID'] = fixture_price
    ENV['STRIPE_PORTAL_CONFIGURATION_ID'] = 'bpc_test'
    ENV['BILLING_ENABLED'] = 'true'
  end

  def fixture_body(name)
    Rails.root.join("spec/fixtures/stripe/#{name}.json").read
  end

  # --- seats (Session 7 Phase B) ---------------------------------------------
  #
  # The two Stripe calls the seat flow makes, kept HERE rather than in either
  # file so the subscription flow and the seat flow can never drift apart
  # about what Stripe answers. Both are capture-shaped: a real subscription
  # capture with the quantity overridden, the way stub_subscription overrides
  # a status.

  def seat_subscription_url(id)
    %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{Regexp.escape(id)}}
  end

  # A real capture with every item (and the top-level mirror) set to the seat
  # count being asserted.
  def subscription_with_quantity(id, quantity, fixture: 'subscription-active', overrides: {})
    body = JSON.parse(fixture_body(fixture)).merge('id' => id, 'quantity' => quantity)

    body['items']['data'].each { |item| item['quantity'] = quantity }

    body.merge(overrides.stringify_keys)
  end

  # What Stripe quotes for one more seat. Nothing is created and nothing is
  # charged by a preview, which is the whole point of showing it first.
  def stub_invoice_preview(amount_cents:, currency: 'usd')
    stub_request(:post, 'https://api.stripe.com/v1/invoices/create_preview')
      .to_return(status: 200,
                 body: { object: 'invoice', amount_due: amount_cents, amount_remaining: amount_cents,
                         currency:, lines: { object: 'list', data: [] } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  # The update that actually buys or releases a seat. `overrides:` is how an
  # example makes Stripe park the change (`pending_update`).
  def stub_subscription_update(id, quantity:, fixture: 'subscription-active', overrides: {})
    stub_request(:post, seat_subscription_url(id))
      .to_return(status: 200,
                 body: subscription_with_quantity(id, quantity, fixture:, overrides:).to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  # The re-read that follows every write (Linker.apply_current!): the row is
  # never trusted to know what it just asked for.
  def stub_subscription_reread(id, quantity:, fixture: 'subscription-active')
    stub_request(:get, seat_subscription_url(id))
      .with(query: hash_including('expand' => StripeBilling::SUBSCRIPTION_EXPAND))
      .to_return(status: 200, body: subscription_with_quantity(id, quantity, fixture:).to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end
end
