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
    # Stripe. Everything apply! would write except `synced_at`, which moves on
    # every run and would report drift on every single row.
    DRIFT_ATTRIBUTES = %i[access_state status stripe_status quantity stripe_item_id stripe_price_id
                          stripe_product_id stripe_subscription_id stripe_customer_id current_period_start
                          current_period_end ended_at trial_end trial_used_at past_due_since
                          cancel_at_period_end].freeze

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
      report_missing_price(account_subscription, stripe_subscription) if price_item(stripe_subscription).nil?

      report_purge_barrier(account_subscription, stripe_subscription) if barred?(account_subscription) &&
                                                                         paid_state?(stripe_subscription)

      account_subscription.assign_attributes(attributes_for(account_subscription, stripe_subscription))
      account_subscription.save!

      # Everything that happens TO the account because of what Stripe just
      # said — dunning mail, suspension at the end of the grace period,
      # lifting one when the card goes through — hangs off this one call, so
      # the webhook, the Checkout return and the nightly sweep all react
      # identically (BillingLifecycle). It never raises.
      BillingLifecycle.after_apply!(account_subscription)

      account_subscription
    end

    # Is this row's account past the point of no return?
    def barred?(account_subscription)
      account_subscription.account&.purge_claimed? == true
    end

    def paid_state?(stripe_subscription)
      Plans::PAID_ACCESS_STATES.include?(access_state_for(stripe_subscription))
    end

    def report_purge_barrier(account_subscription, stripe_subscription)
      subscription_id = field(stripe_subscription, :id)

      OperatorAlert.deliver(
        subject: 'Stripe subscription applied to an account being purged',
        body: "Account #{account_subscription.account_id} is being purged (or already is a tombstone), and " \
              "Stripe reports subscription #{subscription_id} as " \
              "#{field(stripe_subscription, :status)}. The account has NOT been given paid access back, but " \
              'the card may still be being charged — cancel the subscription at Stripe.'
      )

      ErrorReport.warning('stripe subscription applied to an account being purged',
                          account_id: account_subscription.account_id, stripe_subscription_id: subscription_id)
    end

    # A subscription with no item on OUR price is either a subscription that
    # belongs to something else or a price migration nobody told the app
    # about. The row keeps the seats and the price ids it already had — a
    # foreign item's quantity is not a seat count — and a human is told.
    def report_missing_price(account_subscription, stripe_subscription)
      ErrorReport.warning('stripe subscription has no item on our price',
                          account_id: account_subscription.account_id,
                          stripe_subscription_id: field(stripe_subscription, :id),
                          price_id: StripeBilling.price_id)
    end

    # Everything apply! would write, without writing it — reconciliation asks
    # for this and compares before it repairs.
    def attributes_for(account_subscription, stripe_subscription)
      item = price_item(stripe_subscription)
      period_start, period_end = period_for(stripe_subscription, item)
      trial_end = timestamp(field(stripe_subscription, :trial_end))
      status = field(stripe_subscription, :status).to_s
      # THE PURGE BARRIER (review batch 2, R2). Stripe's facts are still
      # written — the ids, the period, the status, so the money history stays
      # readable — but an account whose purge has been claimed, or which is
      # already a tombstone, is never handed paid ACCESS back. Without this a
      # webhook arriving between the claim and the purge would put a
      # half-emptied account back on the paid plan, and the purge's own
      # refusal ("it still holds a live paid subscription") would then stop it
      # finishing: the account would sit part-destroyed and paying.
      #
      # A genuinely live subscription on an account being purged is a money
      # problem rather than an access problem, and `report_purge_barrier`
      # says so to a person — the honest outcome, since only somebody at
      # Stripe can stop the card being charged.
      access_state = barred?(account_subscription) ? 'cancelled' : access_state_for(stripe_subscription)

      {
        access_state:,
        status:,
        stripe_status: status,
        quantity: quantity_for(stripe_subscription, fallback: account_subscription.quantity),
        # Which subscription an account holds is the Linker's decision alone,
        # and it only ever changes one after confirming the old one is over:
        # applying a Stripe object must never repoint a live row.
        stripe_subscription_id: account_subscription.stripe_subscription_id.presence ||
          field(stripe_subscription, :id),
        stripe_customer_id: account_subscription.stripe_customer_id.presence ||
          customer_id(stripe_subscription),
        # No item on our price: keep what the row already knows rather than
        # writing a stranger's ids over it (see report_missing_price).
        stripe_item_id: item ? field(item, :id) : account_subscription.stripe_item_id,
        stripe_price_id: item ? price_id_of(item) : account_subscription.stripe_price_id,
        stripe_product_id: item ? product_id(price_of(item)) : account_subscription.stripe_product_id,
        current_period_start: period_start,
        current_period_end: period_end,
        # When the subscription actually ended — not the same as the end of
        # the period it was paid up to.
        ended_at: ended_at_for(stripe_subscription),
        trial_end:,
        # One trial per account, ever: the stamp is set the first time a
        # subscription with a trial is seen and never cleared afterwards.
        trial_used_at: account_subscription.trial_used_at || (trial_end && Time.current),
        past_due_since: past_due_since_for(account_subscription, access_state),
        cancel_at_period_end: truthy?(field(stripe_subscription, :cancel_at_period_end)),
        synced_at: Time.current
      }
    end

    # The dunning clock, derived from the state that was just applied rather
    # than from the kind of event that triggered the refresh: a stale
    # `invoice.paid` delivered after a newer failure must not stop a clock
    # that is still running, and a recovered account must not keep one.
    # Review-6 C7: `suspended` (Stripe `unpaid` / `paused`) is what a
    # past_due subscription becomes when the retries run out, so it KEEPS the
    # clock rather than resetting it — otherwise a past_due → unpaid →
    # past_due wobble would hand the customer a fresh 14 days every time.
    # Only a healthy state (or one that is over) clears it.
    def past_due_since_for(account_subscription, access_state)
      return account_subscription.past_due_since if access_state == 'suspended'
      return nil unless access_state == 'past_due'

      account_subscription.past_due_since || Time.current
    end

    def ended_at_for(stripe_subscription)
      timestamp(field(stripe_subscription, :ended_at)) || timestamp(field(stripe_subscription, :canceled_at))
    end

    # Seats: the quantity on the items that sit on OUR price, and nothing
    # else. A subscription carrying only foreign items says nothing about how
    # many seats this account bought, so the caller's own count is kept
    # instead of a stranger's. Never below one seat.
    def quantity_for(stripe_subscription, fallback: 1)
      ours = items(stripe_subscription).select { |item| price_id_of(item) == StripeBilling.price_id.to_s }

      return [fallback.to_i, 1].max if ours.empty?

      [ours.sum { |item| field(item, :quantity).to_i }, 1].max
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

    # The item on our price, or nil. Never a foreign item: substituting one
    # would write somebody else's price and product onto the row.
    def price_item(stripe_subscription)
      our_price = StripeBilling.price_id.to_s

      return nil if our_price.blank?

      items(stripe_subscription).find { |item| price_id_of(item) == our_price }
    end

    # `price` is the expanded object when we asked for it and a bare id string
    # when we did not; both name the same price.
    def price_id_of(item)
      price = price_of(item)

      (price.is_a?(String) ? price : field(price, :id)).to_s
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
