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

  # Every Stripe call is on a short leash. A Postgres row lock is held across
  # these calls (StripeBilling::Linker), so a Stripe outage has to surface as
  # a fast failure that retries — never as workers piling up behind a lock.
  # The gem's own defaults (30 s to connect, 80 s to read, 2 retries) would
  # let one call sit for minutes.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15
  MAX_NETWORK_RETRIES = 1

  def client
    configure_transport!

    Stripe::StripeClient.new(api_key, stripe_version: API_VERSION)
  end

  # In this gem the timeouts and the retry count live only on the global
  # configuration, which every StripeClient copies at construction; they are
  # not client options. Set once — each assignment drops the gem's connection
  # pool, so re-setting an equal value on every call would be needless churn.
  def configure_transport!
    Stripe.open_timeout = OPEN_TIMEOUT unless Stripe.open_timeout == OPEN_TIMEOUT
    Stripe.read_timeout = READ_TIMEOUT unless Stripe.read_timeout == READ_TIMEOUT
    Stripe.max_network_retries = MAX_NETWORK_RETRIES unless Stripe.max_network_retries == MAX_NETWORK_RETRIES
  end

  # The transport settings a built client will actually use, read back off
  # the client itself (the gem keeps them on its private requestor).
  def transport_of(stripe_client)
    config = stripe_client.instance_variable_get(:@requestor).config

    { open_timeout: config.open_timeout, read_timeout: config.read_timeout,
      max_network_retries: config.max_network_retries }
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

  # Written into `cancellation_details.comment` of every subscription THIS
  # app cancels as a duplicate — for a HUMAN reading the Stripe dashboard.
  # It is documentation, never authority: the Customer Portal's "tell us
  # more" box writes that same field, so a customer can type this string
  # themselves. No money decision may ever be made on it. See
  # DUPLICATE_CANCEL_METADATA_KEY for the field that does decide.
  DUPLICATE_CANCEL_MARKER = 'esigncenter:duplicate'

  # The same, for a duplicate we cancelled that was created BEFORE the one
  # that survived — the customer's original subscription, ended because it
  # had stopped collecting and a healthy newer one took over. We ended it,
  # but its history bought real service: at most part of one cycle was
  # billed twice and only a person can judge that, so a subscription
  # carrying this marker is NEVER refunded automatically.
  DUPLICATE_CANCEL_MANUAL_MARKER = 'esigncenter:duplicate-manual'

  # Where the marker's AUTHORITY lives. Subscription metadata can only be
  # written with a secret API key — not by the Customer Portal, not by the
  # customer, not by any field they can fill in — so a dead subscription
  # carrying this key is one WE cancelled, and its value alone says whether
  # its money is ours to send back automatically. Written by
  # `subscriptions.update` immediately before the cancel; if that write
  # fails, nothing is cancelled.
  DUPLICATE_CANCEL_METADATA_KEY = 'esigncenter_cancelled'

  # When we did it — for a person reconstructing the sequence later. Never
  # read by any decision.
  DUPLICATE_CANCEL_METADATA_AT_KEY = 'esigncenter_cancelled_at'

  # The metadata value that means "we ended this as a newer duplicate and we
  # owe its money back".
  DUPLICATE_CANCEL_METADATA = 'duplicate'

  # And the value that means "we ended this, but only a person may decide
  # what — if anything — comes back".
  DUPLICATE_CANCEL_MANUAL_METADATA = 'duplicate-manual'

  # Raised when a customer's subscription list could not be read to the end
  # (the page cap was hit with Stripe still saying `has_more`): nothing that
  # depends on "does this customer already have one?" may proceed on it.
  class ListIncomplete < StandardError; end

  # Verifies the Stripe-Signature header against the raw body and returns the
  # parsed Stripe::Event. Raises Stripe::SignatureVerificationError when the
  # signature, the scheme or the 300-second timestamp tolerance fails — the
  # endpoint turns that into a bare 400.
  def webhook_event!(raw_body, signature_header)
    Stripe::Webhook.construct_event(raw_body, signature_header.to_s, webhook_secret.to_s)
  end

  SUBSCRIPTION_EXPAND = ['items.data.price'].freeze

  # The CURRENT state of a subscription, straight from Stripe. Every event
  # handler calls this instead of trusting the delivered payload: deliveries
  # arrive out of order and a stale payload would otherwise win. The price is
  # always expanded (the mapping reads it); a caller that needs more (the
  # duplicate path wants the latest invoice) says so.
  def subscription_for(subscription_id, expand: SUBSCRIPTION_EXPAND)
    client.v1.subscriptions.retrieve(subscription_id, { expand: })
  end

  # Which of the five keys are set and shaped right, without ever reading a
  # value out. Feeds both the boot guard and `rake stripe:check`.
  def config_status
    CONFIG_KEYS.to_h do |name, prefix|
      value = ENV.fetch(name, nil).to_s

      [name, { present: value.present?, prefix:, shape_ok: value.start_with?(prefix) }]
    end
  end

  # 'live', 'test' or nil — read from each key's own prefix, so a test key
  # in a production deployment (or a live secret paired with a test
  # publishable key) is a fact the guard can refuse on. The two keys are
  # judged independently: the browser and the server must be on the same
  # Stripe account.
  def key_mode
    secret_key_mode
  end

  def secret_key_mode
    mode_of(api_key, 'sk')
  end

  def publishable_key_mode
    mode_of(publishable_key, 'pk')
  end

  def mode_of(value, prefix)
    case value.to_s
    when /\A#{prefix}_live_/ then 'live'
    when /\A#{prefix}_test_/ then 'test'
    end
  end

  def configured?
    config_status.values.all? { |state| state[:present] && state[:shape_ok] }
  end
end
