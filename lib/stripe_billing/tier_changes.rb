# frozen_string_literal: true

module StripeBilling
  # The account lock serialises requested recurring quantities with seat
  # changes and webhooks. Paid pack additions leave a durable operation before
  # any invoice is created; PackPurchases owns charging and later recovery.
  module TierChanges
    class Unavailable < StandardError; end

    module_function

    def change_plan!(row, plan)
      raise Unavailable, 'billing_change_unavailable' unless [Plans::PAID, Plans::BUSINESS].include?(plan)
      raise Unavailable, 'billing_business_unavailable' if plan == Plans::BUSINESS && !StripeBilling.business_available?

      with_subscription(row) do |subscription|
        next :updated if row.plan == plan

        # The price being moved onto must be the one the app sells, in the
        # key's mode, before Stripe is asked to charge anything for it.
        PriceGuard.verify!(plan == Plans::BUSINESS ? :business : :seat)

        # Restoring a Business period already paid for is not another sale.
        # Downgrades never credit that period: the lower recurring price is
        # for renewal, while effective_plan retains the current allowance.
        charge = plan == Plans::BUSINESS && row.effective_plan != Plans::BUSINESS && row.access_state != 'trialing'
        params = { items: plan_items(subscription, plan, row.quantity),
                   proration_behavior: charge ? 'always_invoice' : 'none' }
        params[:payment_behavior] = 'pending_if_incomplete' if charge
        changed = update_subscription!(row, params, "plan-#{plan}")
        result = BillingLifecycle.pending_update?(changed) ? :pending : :updated
        Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)

        result
      end
    end

    def change_packs!(row, raw_quantity)
      raise Unavailable, 'billing_api_packs_unavailable' unless StripeBilling.api_packs_available?
      raise Unavailable, 'billing_api_packs_invalid' unless raw_quantity.match?(/\A\d{1,4}\z/)

      quantity = raw_quantity.to_i
      outcome = with_subscription(row, allow_pack_purchase: true) do |subscription|
        existing = row.api_pack_purchases.open.first
        if existing
          raise Unavailable, 'billing_change_pending' unless existing.quantity == quantity

          next existing
        end
        next :updated if row.api_pack_quantity == quantity

        PriceGuard.verify!(:api_pack) if quantity > row.api_pack_quantity

        prepare_packs!(row, subscription, quantity)
      end

      outcome.is_a?(ApiPackPurchase) ? PackPurchases.process!(outcome) : outcome
    end

    # A trial pays for new packs up front like any other period: capacity a
    # trial could add for free would be free capacity for anyone who cancels
    # before trial end. Removals stop recurring at renewal while retained
    # capacity lasts until then. Restoring that owned capacity must not
    # charge twice.
    def prepare_packs!(row, subscription, quantity)
      covered = row.effective_api_pack_quantity
      if quantity <= covered
        write_packs!(row, subscription, quantity)
        Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)

        return :updated
      end

      # Restore existing capacity before invoicing the NEW units. Otherwise
      # an unpaid invoice crossing renewal could restore expired packs for
      # free. This no-charge part survives even when the added units await a
      # card step; the recurring quantity shown on Billing says so.
      if covered > row.api_pack_quantity
        write_packs!(row, subscription, covered)
        Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)
      end

      row.api_pack_purchases.create!(operation_key: SecureRandom.uuid,
                                     stripe_subscription_id: row.stripe_subscription_id,
                                     stripe_customer_id: row.stripe_customer_id,
                                     previous_quantity: covered, quantity:, added_quantity: quantity - covered,
                                     expires_at: 1.day.from_now)
    end

    def with_subscription(row, allow_pack_purchase: false)
      raise Unavailable, 'billing_change_unavailable' unless row && BillingLifecycle.manageable?(row)

      Linker.with_account_lock(row) do
        if AccountLimitOverride.where(account_id: row.account_id).where.not(api_completions_per_month: nil).exists?
          raise Unavailable, 'billing_capacity_by_agreement'
        end
        raise Unavailable, 'billing_change_unavailable' if row.stripe_subscription_id.blank?
        raise Unavailable, 'billing_change_pending' if !allow_pack_purchase && row.api_pack_purchases.open.exists?

        subscription = StripeBilling.subscription_for(row.stripe_subscription_id)
        SubscriptionSync.apply!(row, subscription)
        assert_changeable!(row, subscription)

        yield subscription
      end
    end

    def assert_changeable!(row, subscription)
      unless %w[active trialing].include?(row.access_state) && SubscriptionSync.price_item(subscription)
        raise Unavailable, 'billing_change_unavailable'
      end
      if row.plan == Plans::BUSINESS && !StripeBilling.business_available?
        raise Unavailable, 'billing_business_unavailable'
      end
      raise Unavailable, 'billing_change_pending' if BillingLifecycle.pending_update?(subscription)
      raise Unavailable, 'billing_change_unavailable' if SubscriptionSync.field(subscription, :schedule).present?
    end

    # An upgrade swaps the existing Paid item's PRICE and adds extra seats.
    # No pending update ever contains deleted: Stripe rejects that pairing.
    # A downgrade may remove a base item, but it is a no-charge update with
    # no pending payment mode, so the deletion is supported.
    def plan_items(subscription, plan, seats)
      business = SubscriptionSync.item_for_price(subscription, StripeBilling.business_price_id)
      seat = SubscriptionSync.item_for_price(subscription, StripeBilling.price_id)
      if plan == Plans::BUSINESS
        return [{ id: SubscriptionSync.field(seat, :id), price: StripeBilling.business_price_id, quantity: 1 },
                item_change(nil, StripeBilling.price_id, seats - 1)].compact
      end
      return [{ id: SubscriptionSync.field(business, :id), price: StripeBilling.price_id, quantity: seats }] unless seat

      [{ id: SubscriptionSync.field(business, :id), deleted: true },
       { id: SubscriptionSync.field(seat, :id), quantity: seats }]
    end

    def item_change(item, price, quantity)
      return if item.nil? && quantity.zero?
      return { id: SubscriptionSync.field(item, :id), deleted: true } if quantity.zero?
      return { id: SubscriptionSync.field(item, :id), quantity: } if item

      { price:, quantity: }
    end

    def write_packs!(row, subscription, quantity)
      item = item_change(pack_item(subscription), StripeBilling.api_pack_price_id, quantity)
      update_subscription!(row, { items: [item], proration_behavior: 'none' }, "packs-#{quantity}")
    end

    def update_subscription!(row, params, suffix)
      StripeBilling.client.v1.subscriptions.update(
        row.stripe_subscription_id, params,
        { idempotency_key: "tier-#{row.stripe_subscription_id}-#{row.updated_at.to_f}-#{suffix}" }
      )
    end

    def pack_item(subscription)
      SubscriptionSync.item_for_price(subscription, StripeBilling.api_pack_price_id)
    end
  end
end
