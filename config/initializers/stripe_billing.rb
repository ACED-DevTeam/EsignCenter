# frozen_string_literal: true

# Nothing about Stripe is cached at boot: the API key, the webhook secret and
# the price live behind lazy readers (lib/stripe_billing.rb) so the test suite
# can hand each example its own fake credentials. This initializer only checks
# that a deployment with billing switched on actually has what it needs.
Rails.application.config.after_initialize do
  StripeBilling::ConfigGuard.check!
end
