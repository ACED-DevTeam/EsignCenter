# frozen_string_literal: true

# The console is loaded in the web process only (never in Sidekiq workers or
# rake tasks). The test process has no Puma, so it loads there explicitly to
# keep the operator-only /jobs route under test.
if defined?(Puma) || Rails.env.test?
  require 'sidekiq/web'
  require 'sidekiq/cron/web'
end

if !ENV['SIDEKIQ_BASIC_AUTH_PASSWORD'].to_s.empty? && defined?(Sidekiq::Web)
  Sidekiq::Web.use(Rack::Auth::Basic) do |_, password|
    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(password),
      Digest::SHA256.hexdigest(ENV.fetch('SIDEKIQ_BASIC_AUTH_PASSWORD'))
    )
  end
end

Sidekiq.strict_args!

# Recurring jobs: sidekiq-cron's own startup hook loads config/schedule.yml
# (its default schedule file) when a Sidekiq server boots, registering each
# job with source "schedule" — which is what lets it purge jobs that were
# removed from the file on the next deploy. Nothing here touches Redis in
# the web or test process, and nothing here loads the schedule a second
# time (a second load without that source would re-register every job as
# "dynamic" and defeat the purge).
