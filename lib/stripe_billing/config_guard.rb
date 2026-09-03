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

      mode_problem = key_mode_problem

      mode_problem ? problems << mode_problem : problems
    end

    def key_mode_problem
      mode = StripeBilling.key_mode

      if Rails.env.production?
        'STRIPE_SECRET_KEY is a test key but this is production' if mode == 'test'
      elsif mode == 'live'
        'STRIPE_SECRET_KEY is a LIVE key outside production'
      end
    end
  end
end
