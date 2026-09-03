# frozen_string_literal: true

# Everything the app needs to talk to Stripe, read LAZILY.
#
# Nothing here may be memoised into a constant at boot: the test suite scrubs
# every key of .env.standalone.local out of ENV before Rails loads and each
# example sets its own fake credentials, so the values must be read at call
# time. `client` builds a fresh Stripe::StripeClient with the API version this
# app is written against pinned explicitly — the gem's own default moves with
# the gem, ours does not.
module StripeBilling
  # The Stripe API version every request is made against. Changing it is a
  # deliberate migration, never a side effect of a gem bump.
  API_VERSION = '2026-08-26.dahlia'

  module_function

  def api_key
    ENV.fetch('STRIPE_SECRET_KEY', nil)
  end

  def publishable_key
    ENV.fetch('STRIPE_PUBLISHABLE_KEY', nil)
  end

  def webhook_secret
    ENV.fetch('STRIPE_WEBHOOK_SECRET', nil)
  end

  def price_id
    ENV.fetch('STRIPE_PRICE_ID', nil)
  end

  def portal_configuration_id
    ENV.fetch('STRIPE_PORTAL_CONFIGURATION_ID', nil)
  end

  def client
    Stripe::StripeClient.new(api_key, stripe_version: API_VERSION)
  end

  # The env keys Stripe needs and the prefix each real value carries. The
  # prefix check is a typo guard, not a secret check: it catches a publishable
  # key pasted into the secret slot long before a customer meets it.
  CONFIG_KEYS = {
    'STRIPE_SECRET_KEY' => 'sk_',
    'STRIPE_PUBLISHABLE_KEY' => 'pk_',
    'STRIPE_WEBHOOK_SECRET' => 'whsec_',
    'STRIPE_PRICE_ID' => 'price_',
    'STRIPE_PORTAL_CONFIGURATION_ID' => 'bpc_'
  }.freeze

  # What the app charges for, restated here so `rake stripe:check` can assert
  # the live price still matches the product we sell (docs/billing.md).
  PRICE_UNIT_AMOUNT = 1000
  PRICE_CURRENCY = 'usd'
  PRICE_INTERVAL = 'month'

  TRIAL_PERIOD_DAYS = 14

  # Verifies the Stripe-Signature header against the raw body and returns the
  # parsed Stripe::Event. Raises Stripe::SignatureVerificationError when the
  # signature, the scheme or the 300-second timestamp tolerance fails — the
  # endpoint turns that into a bare 400.
  def webhook_event!(raw_body, signature_header)
    Stripe::Webhook.construct_event(raw_body, signature_header.to_s, webhook_secret.to_s)
  end

  # The CURRENT state of a subscription, straight from Stripe. Every event
  # handler calls this instead of trusting the delivered payload: deliveries
  # arrive out of order and a stale payload would otherwise win.
  def subscription_for(subscription_id)
    client.v1.subscriptions.retrieve(subscription_id, { expand: ['items.data.price'] })
  end

  # Which of the five keys are set and shaped right, without ever reading a
  # value out. Feeds both the boot guard and `rake stripe:check`.
  def config_status
    CONFIG_KEYS.to_h do |name, prefix|
      value = ENV.fetch(name, nil).to_s

      [name, { present: value.present?, prefix:, shape_ok: value.start_with?(prefix) }]
    end
  end

  # 'live', 'test' or nil — read from the secret key's own prefix, so a test
  # key in a production deployment is a fact the guard can refuse on.
  def key_mode
    case api_key.to_s
    when /\Ask_live_/ then 'live'
    when /\Ask_test_/ then 'test'
    end
  end

  def configured?
    config_status.values.all? { |state| state[:present] && state[:shape_ok] }
  end
end
