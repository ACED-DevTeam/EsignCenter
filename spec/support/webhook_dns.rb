# frozen_string_literal: true

# Webhook delivery and URL downloads resolve the target host themselves
# (OutboundAddress pins the request to a checked address). The suite runs
# offline, so every name resolves to one public address unless an example says
# otherwise; examples about resolution stub `resolve` (or the webhook's
# `resolve_addresses`) again, or call the original.
RSpec.configure do |config|
  config.before do
    allow(OutboundAddress).to receive(:resolve).and_return([IPAddr.new('93.184.215.14')])
  end
end
