# frozen_string_literal: true

module StripeBilling
  # The ONE place a Stripe subscription becomes an AccountSubscription row.
  # Stripe owns the facts (status, quantity, period, trial); the app owns the
  # verdict (`access_state`, which Plans reads to decide paid or free). Every
  # webhook, the Checkout return and the nightly reconciliation all land here,
  # so there is exactly one mapping to reason about — and it is idempotent:
  # applying the same Stripe object twice writes the same row.
  #
  # A downgrade never purges (D43): when Stripe says `canceled` the row keeps
  # every id it had, so the history stays readable and a later Checkout simply
  # brings a new subscription id.
  module SubscriptionSync
    # Stripe status → the app's access state, before the cancel-at-period-end
    # flag is considered. A status we do not know is treated as `cancelled`:
    # paid access is never granted on a word we cannot explain.
    STATE_BY_STRIPE_STATUS = {
      'trialing' => 'trialing',
      'active' => 'active',
      'past_due' => 'past_due',
      'unpaid' => 'suspended',
      'paused' => 'suspended',
      'incomplete' => 'cancelled',
      'incomplete_expired' => 'cancelled',
      'canceled' => 'cancelled'
    }.freeze

    # Only a subscription that is still running can be "cancelling": a
    # past_due or unpaid one carries the flag too, and its state is the
    # payment problem, not the pending cancellation.
    CANCELING_FROM = %w[trialing active].freeze

    # The columns reconciliation compares to decide a row has drifted from
    # Stripe. `synced_at` and `trial_used_at` are stamps, not facts about the
    # subscription, so they never count as drift.
    DRIFT_ATTRIBUTES = %i[access_state status stripe_status quantity stripe_item_id stripe_price_id
                          stripe_product_id stripe_subscription_id current_period_start current_period_end
                          trial_end cancel_at_period_end].freeze

    module_function

    # Pure: what access state this Stripe subscription means. Takes a
    # Stripe::Subscription or any hash shaped like one (the state-table spec
    # feeds it modified copies of real captures).
    def access_state_for(stripe_subscription)
      status = field(stripe_subscription, :status).to_s

      return 'canceling' if truthy?(field(stripe_subscription, :cancel_at_period_end)) &&
                            CANCELING_FROM.include?(status)

      STATE_BY_STRIPE_STATUS.fetch(status, 'cancelled')
    end

    def apply!(account_subscription, stripe_subscription)
      account_subscription.assign_attributes(attributes_for(account_subscription, stripe_subscription))
      account_subscription.save!

      account_subscription
    end

    # Everything apply! would write, without writing it — reconciliation asks
    # for this and compares before it repairs.
    def attributes_for(account_subscription, stripe_subscription)
      item = price_item(stripe_subscription)
      period_start, period_end = period_for(stripe_subscription, item)
      trial_end = timestamp(field(stripe_subscription, :trial_end))
      status = field(stripe_subscription, :status).to_s

      {
        access_state: access_state_for(stripe_subscription),
        status:,
        stripe_status: status,
        quantity: quantity_for(stripe_subscription),
        stripe_subscription_id: field(stripe_subscription, :id).presence ||
          account_subscription.stripe_subscription_id,
        stripe_customer_id: account_subscription.stripe_customer_id.presence ||
          customer_id(stripe_subscription),
        stripe_item_id: item && field(item, :id),
        stripe_price_id: item && field(price_of(item), :id),
        stripe_product_id: item && product_id(price_of(item)),
        current_period_start: period_start,
        current_period_end: period_end,
        trial_end:,
        # One trial per account, ever: the stamp is set the first time a
        # subscription with a trial is seen and never cleared afterwards.
        trial_used_at: account_subscription.trial_used_at || (trial_end && Time.current),
        cancel_at_period_end: truthy?(field(stripe_subscription, :cancel_at_period_end)),
        synced_at: Time.current
      }
    end

    # Seats. The items on our own price are what the account is billed for; a
    # subscription carrying only foreign items (an old price, a fixture) still
    # yields an honest seat count rather than zero, and the row can never drop
    # below one seat.
    def quantity_for(stripe_subscription)
      all_items = items(stripe_subscription)
      ours = all_items.select { |item| field(price_of(item), :id).to_s == StripeBilling.price_id.to_s }
      counted = ours.presence || all_items

      [counted.sum { |item| field(item, :quantity).to_i }, 1].max
    end

    # In this API version the billing period lives on the subscription ITEM;
    # older versions carried it on the subscription itself. Read the item
    # first, fall back to the top-level keys when they are present.
    def period_for(stripe_subscription, item)
      start_at = timestamp(item && field(item, :current_period_start)) ||
                 timestamp(field(stripe_subscription, :current_period_start))
      end_at = timestamp(item && field(item, :current_period_end)) ||
               timestamp(field(stripe_subscription, :current_period_end))

      [start_at, end_at]
    end

    def price_item(stripe_subscription)
      all_items = items(stripe_subscription)

      all_items.find { |item| field(price_of(item), :id).to_s == StripeBilling.price_id.to_s } || all_items.first
    end

    def items(stripe_subscription)
      Array(field(field(stripe_subscription, :items), :data))
    end

    def price_of(item)
      field(item, :price) || field(item, :plan)
    end

    # `product` is a bare id unless the caller expanded it.
    def product_id(price)
      product = field(price, :product)

      product.is_a?(String) ? product : field(product, :id)
    end

    def customer_id(stripe_subscription)
      customer = field(stripe_subscription, :customer)

      customer.is_a?(String) ? customer : field(customer, :id)
    end

    # Reads a field off a Stripe::StripeObject or a plain Hash with either
    # symbol or string keys, so the same mapping serves live objects and
    # captured fixtures.
    def field(object, key)
      return nil if object.nil?

      value = object[key.to_sym] if object.respond_to?(:[])
      value = object[key.to_s] if value.nil? && object.respond_to?(:[])

      value
    rescue TypeError, NoMethodError
      nil
    end

    def timestamp(value)
      return nil if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.at(value.to_i)
    end

    def truthy?(value)
      value == true || value.to_s == 'true'
    end
  end
end
