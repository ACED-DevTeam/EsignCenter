# frozen_string_literal: true

module StripeBilling
  # The runtime half of the price check `rake stripe:check` makes (launch
  # review: a test-mode price with a live key boots fine, then every Checkout
  # fails "No such price"). Boot never asks Stripe anything — a Stripe outage
  # must not stop the app starting — so the price a sale is about to use is
  # checked at the moment of the sale instead: same Stripe mode as the key,
  # active, USD, monthly, and the amount the app says it charges.
  #
  # A wrong price refuses the sale with a plain sentence for the customer and
  # tells the operator (Sentry + the operator alert email, at most once an
  # hour per price and process). A good answer is remembered for a few
  # minutes, so a busy checkout does not ask Stripe on every click. A Stripe
  # that cannot be reached raises its own error, which the billing page
  # already turns into "try again in a minute".
  module PriceGuard
    class Misconfigured < StandardError; end

    VERIFIED_FOR = 10.minutes
    ALERT_EVERY = 1.hour

    module_function

    # What each sellable price must look like. Price ids are not secrets.
    def expectation(role)
      case role
      when :seat
        { id: StripeBilling.price_id, amount: StripeBilling::PRICE_UNIT_AMOUNT, env: 'STRIPE_PRICE_ID' }
      when :business
        { id: StripeBilling.business_price_id, amount: StripeBilling::BUSINESS_BASE_USD * 100,
          env: 'STRIPE_BUSINESS_PRICE_ID' }
      when :api_pack
        { id: StripeBilling.api_pack_price_id, amount: StripeBilling::API_PACK_USD * 100,
          env: 'STRIPE_API_PACK_PRICE_ID' }
      else
        raise ArgumentError, "unknown price role #{role.inspect}"
      end
    end

    def verify!(role)
      wanted = expectation(role)
      cache_key = ['stripe-price-ok', StripeBilling.secret_key_mode, wanted[:id], wanted[:amount]].join(':')

      return true if Rails.cache.read(cache_key)

      problems = fetch_problems(wanted)

      if problems.empty?
        Rails.cache.write(cache_key, true, expires_in: VERIFIED_FOR)

        return true
      end

      alert!(wanted, problems)

      raise Misconfigured, "#{wanted[:env]} (#{wanted[:id]}): #{problems.join('; ')}"
    end

    def fetch_problems(wanted)
      return ['is not set'] if wanted[:id].blank?

      problems_for(StripeBilling.client.v1.prices.retrieve(wanted[:id]), wanted[:amount])
    rescue Stripe::InvalidRequestError => e
      # Stripe's 404: the id belongs to the other mode or another account.
      raise unless e.code.to_s == Linker::RESOURCE_MISSING

      ["was not found with the configured #{StripeBilling.secret_key_mode || 'unrecognised'} secret key"]
    end

    # Every way a price can be the wrong thing to sell. Read through `field`,
    # which answers nil for a property Stripe did not send.
    def problems_for(price, amount)
      livemode = SubscriptionSync.field(price, :livemode)
      currency = SubscriptionSync.field(price, :currency)
      unit_amount = SubscriptionSync.field(price, :unit_amount)
      recurring = SubscriptionSync.field(price, :recurring)
      interval = SubscriptionSync.field(recurring, :interval)
      interval_count = SubscriptionSync.field(recurring, :interval_count)
      problems = []

      if livemode != expected_livemode
        problems << "livemode=#{livemode.inspect} does not match the #{key_mode_label} secret key"
      end
      problems << 'is not active' unless SubscriptionSync.field(price, :active) == true
      if currency != StripeBilling::PRICE_CURRENCY
        problems << "currency #{currency.inspect} (expected #{StripeBilling::PRICE_CURRENCY})"
      end
      problems << "amount #{unit_amount.inspect} (expected #{amount})" if unit_amount != amount
      unless interval == StripeBilling::PRICE_INTERVAL && interval_count.to_i == 1
        problems << "interval #{interval_count.inspect} #{interval.inspect} (expected 1 #{StripeBilling::PRICE_INTERVAL})"
      end

      problems
    end

    def expected_livemode
      StripeBilling.secret_key_mode == 'live'
    end

    def key_mode_label
      StripeBilling.secret_key_mode || 'unrecognised'
    end

    def alert!(wanted, problems)
      alert_key = ['stripe-price-alert', wanted[:env], wanted[:id]].join(':')

      return if Rails.cache.read(alert_key)

      Rails.cache.write(alert_key, true, expires_in: ALERT_EVERY)

      message = "Stripe price refused at checkout: #{wanted[:env]} (#{wanted[:id]}) #{problems.join('; ')}. " \
                'Customers cannot buy it until the price is fixed; run rake stripe:check.'

      ErrorReport.error(message, price_env: wanted[:env])
      OperatorAlert.deliver(subject: 'Stripe price misconfigured — purchases refused', body: message)
    end
  end
end
