# frozen_string_literal: true

# The console is loaded in the web process only (never in Sidekiq workers or
# rake tasks). The test process has no Puma, so it loads there explicitly to
# keep the operator-only /jobs route under test.
require 'sidekiq/web' if defined?(Puma) || Rails.env.test?

if !ENV['SIDEKIQ_BASIC_AUTH_PASSWORD'].to_s.empty? && defined?(Sidekiq::Web)
  Sidekiq::Web.use(Rack::Auth::Basic) do |_, password|
    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(password),
      Digest::SHA256.hexdigest(ENV.fetch('SIDEKIQ_BASIC_AUTH_PASSWORD'))
    )
  end
end

Sidekiq.strict_args!
