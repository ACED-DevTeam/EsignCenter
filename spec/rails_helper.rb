# frozen_string_literal: true

require 'spec_helper'
# Forced, not defaulted: the dev container ships RAILS_ENV=development, and with `||=`
# a bare `bundle exec rspec` there ran the whole suite against the development
# database and config (review 10, 2026-09-06: three full runs, 750+ spurious
# failures, dev data at risk). A spec process is a test process, full stop.
ENV['RAILS_ENV'] = 'test'
ENV['TZ'] ||= 'UTC'

# The dev container loads .env.standalone.local (real SMTP/TSA/Stripe credentials) for the
# staging walk. Specs must stay hermetic: every spec that needs one of these vars sets it
# itself, so scrub exactly the keys that file declares before Rails boots.
env_local = File.expand_path('../.env.standalone.local', __dir__)
if File.exist?(env_local)
  File.readlines(env_local).each do |line|
    key = line[/\A([A-Z][A-Z0-9_]*)=/, 1]
    ENV.delete(key) if key
  end
end
# The same rule for the delivery-mode switch, which the env file does not declare: a dev
# container recreated for a staging walk with EMAIL_DELIVERY_MODE=smtp otherwise hands
# that mode to the test process, and a spec that exercises an SMTP setup then opens a
# real socket (seen 2026-09-06: "getaddrinfo(3): Name does not resolve"). Specs that need
# a mode set it themselves (spec/support/isolated_smtp_environment.rb).
ENV.delete('EMAIL_DELIVERY_MODE')

require_relative '../config/environment'
abort('The Rails environment is running in production mode!') if Rails.env.production? # rubocop:disable Rails/Exit
require 'rspec/rails'
require 'capybara/cuprite'
require 'capybara/rspec'
require 'webmock/rspec'
require 'signing_form_helper'

Sidekiq.testing!(:fake)

WebMock.disable_net_connect!(allow_localhost: true)

require 'simplecov' if ENV['COVERAGE']

Capybara.server = :puma, { Silent: true }
Capybara.disable_animation = true
# Capybara's own default is 2 seconds, which is what a headless Chrome inside
# Docker on a busy box takes to finish an ordinary form POST, redirect and full
# page swap. Every system-spec flake this project has recorded looks the same:
# the screenshot taken after the timeout shows the page rendered perfectly.
# Five seconds costs nothing when things are quick — a wait ends the moment the
# expectation holds — and stops the suite reporting slowness as failure.
Capybara.default_max_wait_time = 5

Capybara.register_driver(:headless_cuprite) do |app|
  Capybara::Cuprite::Driver.new(app, window_size: [1200, 800],
                                     process_timeout: 20,
                                     timeout: 20,
                                     js_errors: true,
                                     browser_options: { 'no-sandbox' => nil })
end

Capybara.register_driver(:headful_cuprite) do |app|
  Capybara::Cuprite::Driver.new(app, window_size: [1200, 800],
                                     headless: false,
                                     process_timeout: 20,
                                     timeout: 20,
                                     js_errors: true,
                                     browser_options: { 'no-sandbox' => nil })
end

Rails.root.glob('spec/support/**/*.rb').each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip # rubocop:disable Rails/Exit
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include Devise::Test::IntegrationHelpers
  config.include SigningFormHelper
  config.include ActiveSupport::Testing::TimeHelpers

  config.before(:each, type: :system) do
    if ENV['HEADLESS'] == 'false'
      driven_by :headful_cuprite
    else
      driven_by :headless_cuprite
    end
  end

  config.before do
    Sidekiq::Worker.clear_all
  end

  config.before do |example|
    Sidekiq.testing!(:inline) if example.metadata[:sidekiq] == :inline
  end

  config.after do |example|
    Sidekiq.testing!(:fake) if example.metadata[:sidekiq] == :inline
  end

  config.before(multitenant: true) do
    allow(Docuseal).to receive(:multitenant?).and_return(true)
  end
end

ActiveSupport.run_load_hooks(:rails_specs, self)
