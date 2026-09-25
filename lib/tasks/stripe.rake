# frozen_string_literal: true

# Operator tools for the Stripe side of billing. `stripe:check` asserts that
# the live Stripe account still matches what the app assumes (the price we
# sell, a Customer Portal that cannot edit seats, an endpoint pointed at us);
# `stripe:portal_configuration` builds that portal from the manifest in
# lib/stripe_billing/checks.rb, so nobody has to configure it by hand in a
# dashboard where the change leaves no trace. Both live in
# StripeBilling::Checks; these tasks are only the door.
namespace :stripe do
  desc 'Assert the live Stripe account matches what the app assumes: rake stripe:check'
  task check: :environment do
    rows = StripeBilling::Checks.rows

    puts StripeBilling::Checks.table(rows)

    abort("\nstripe:check FAILED") if StripeBilling::Checks.failed?(rows)

    puts "\nstripe:check passed"
  end

  desc 'Create (or find) the optional D79 Business and API pack prices: rake stripe:api_prices'
  task api_prices: :environment do
    [['esigncenter_business_monthly', 'EsignCenter Business', StripeBilling::BUSINESS_BASE_USD,
      'STRIPE_BUSINESS_PRICE_ID'],
     ['esigncenter_api_pack_monthly', 'EsignCenter API pack (50 completions)', StripeBilling::API_PACK_USD,
      'STRIPE_API_PACK_PRICE_ID']].each do |lookup_key, name, dollars, env_key|
      prices = StripeBilling.client.v1.prices
      price = prices.list({ lookup_keys: [lookup_key], active: true, limit: 1 }).data.first
      price ||= prices.create(
        { currency: StripeBilling::PRICE_CURRENCY, unit_amount: dollars * 100,
          recurring: { interval: StripeBilling::PRICE_INTERVAL }, lookup_key:, product_data: { name: } },
        { idempotency_key: lookup_key }
      )

      puts "#{env_key}=#{price.id}"
    end
    puts 'Save these price ids in the deployment environment, then run rake stripe:check.'
  end

  desc 'Create (or find) the Customer Portal configuration: rake stripe:portal_configuration'
  task portal_configuration: :environment do
    version = StripeBilling::Checks::MANIFEST_VERSION
    configurations = StripeBilling.client.v1.billing_portal.configurations

    existing = configurations.list({ limit: 100 }).data.find do |configuration|
      configuration.active && configuration.metadata['esigncenter_manifest_version'] == version
    end

    if existing
      puts "A portal configuration for manifest version #{version} already exists: #{existing.id}"
    else
      existing = configurations.create(StripeBilling::Checks.portal_params)

      puts "Created Customer Portal configuration #{existing.id} (manifest version #{version})"
    end

    puts ''
    puts 'Put this in the environment file (never commit it):'
    puts "  STRIPE_PORTAL_CONFIGURATION_ID=#{existing.id}"
  end
end
