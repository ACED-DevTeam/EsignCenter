# frozen_string_literal: true

# RateLimit.store is one process-wide MemoryStore in test. Every rate-limited
# door (the provisioning endpoint included) starts each example with an empty
# budget, so a limit tripped by one file never leaks into the next.
RSpec.configure do |config|
  config.before { RateLimit.store.clear }
end
