# frozen_string_literal: true

module StripeBilling
  # Boot guard, in the shape of config/initializers/timestamp_server_guard.rb:
  # a production deployment with billing switched on must carry all five
  # Stripe settings, each shaped like the thing it names, and a LIVE secret
  # key — a test key in production would take real customers through a
  # sandbox and silently never charge anyone. Anywhere else it only warns, and
  # it never prints a value.
  module ConfigGuard
    module_function

    def check!
      return unless Docuseal.billing_enabled?

      problems = problems_with_config

      return if problems.empty?

      message = "Stripe billing is enabled but misconfigured: #{problems.join('; ')}"

      raise message if Rails.env.production?

      Rails.logger.warn(message) unless Rails.env.test?
    end

    def problems_with_config
      problems = StripeBilling.config_status.filter_map do |name, state|
        next "#{name} is not set" unless state[:present]

        unless state[:shape_ok]
          "#{name} does not look like a Stripe value (expected it to start with #{state[:prefix]})"
        end
      end

      # Optional additions may be absent on an existing Paid deployment.
      # A supplied malformed or reused price is a configuration error: a seat
      # price mistaken for a pack price would grant capacity on seat count.
      optional = StripeBilling::OPTIONAL_CONFIG_KEYS.filter_map do |name|
        value = ENV.fetch(name, nil)
        next if value.blank? || value.start_with?('price_')

        "#{name} does not look like a Stripe price (expected price_)"
      end
      prices = [StripeBilling.price_id, StripeBilling.business_price_id, StripeBilling.api_pack_price_id].compact_blank
      optional << 'Stripe seat, Business and API pack prices must be distinct' if prices.uniq.size != prices.size

      problems + optional + key_mode_problems
    end

    # The mode has to be POSITIVELY right, not merely "not obviously wrong":
    # a key that is neither sk_live_ nor sk_test_ (a truncated paste, a
    # placeholder) has no mode at all, and production booting on one would
    # take real customers to a checkout that never charges. Both keys are
    # held to the same mode, so the server and the browser can never be
    # pointed at two different Stripe accounts.
    KEYS_WITH_MODE = {
      'STRIPE_SECRET_KEY' => %w[sk secret_key_mode],
      'STRIPE_PUBLISHABLE_KEY' => %w[pk publishable_key_mode]
    }.freeze

    def key_mode_problems
      wanted = Rails.env.production? ? 'live' : 'test'

      KEYS_WITH_MODE.filter_map do |name, (prefix, reader)|
        next if StripeBilling.public_send(reader) == wanted

        "#{name} must be a #{wanted} key (#{prefix}_#{wanted}_…) " \
          "#{Rails.env.production? ? 'in production' : 'outside production'}"
      end
    end
  end
end
