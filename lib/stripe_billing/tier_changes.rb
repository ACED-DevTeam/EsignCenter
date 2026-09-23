# frozen_string_literal: true

module StripeBilling
  # D79's two billing controls share the same account lock as Checkout, seat
  # purchases and webhook application. Stripe's answer, never the requested
  # quantity, grants capacity. Incomplete payments therefore leave both the
  # plan and the allowance alone until Stripe confirms them through sync.
  module TierChanges
    class Unavailable < StandardError; end

    module_function

    def change_plan!(row, plan)
      raise Unavailable, 'billing_change_unavailable' unless [Plans::PAID, Plans::BUSINESS].include?(plan)
      raise Unavailable, 'billing_business_unavailable' if plan == Plans::BUSINESS && !StripeBilling.business_available?

      with_subscription(row) do |subscription|
        next :updated if row.plan == plan

        items = plan_items(subscription, plan, row.quantity)

        update!(row, items, "plan-#{plan}")
      end
    end

    def change_packs!(row, raw_quantity)
      raise Unavailable, 'billing_api_packs_unavailable' unless StripeBilling.api_packs_available?
      raise Unavailable, 'billing_api_packs_invalid' unless raw_quantity.match?(/\A\d{1,4}\z/)

      quantity = raw_quantity.to_i

      with_subscription(row) do |subscription|
        # Trial items do not have a billable remainder to prorate. Selling
        # packs here would grant arbitrary capacity before charging for it;
        # plan trials keep their included allowance until the trial ends.
        raise Unavailable, 'billing_api_packs_trial' if row.access_state == 'trialing'
        next :updated if row.api_pack_quantity == quantity

        # Restoring packs that still cover this paid period must not invoice
        # their remainder a second time. Restore that part without proration,
        # then charge only capacity above what the account already owns.
        covered = [quantity, row.effective_api_pack_quantity].min
        subscription = write_packs!(row, subscription, covered, proration: 'none') if covered > row.api_pack_quantity

        if quantity != SubscriptionSync.field(pack_item(subscription), :quantity).to_i
          subscription = write_packs!(row, subscription, quantity,
                                      proration: quantity > covered ? 'always_invoice' : 'none')
        end

        result = BillingLifecycle.pending_update?(subscription) ? :pending : :updated
        Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)

        result
      end
    end

    def with_subscription(row)
      raise Unavailable, 'billing_change_unavailable' unless row && BillingLifecycle.manageable?(row)

      Linker.with_account_lock(row) do
        raise Unavailable, 'billing_change_unavailable' if row.stripe_subscription_id.blank?

        subscription = StripeBilling.subscription_for(row.stripe_subscription_id)
        SubscriptionSync.apply!(row, subscription)

        unless %w[active trialing].include?(row.access_state) && SubscriptionSync.price_item(subscription)
          raise Unavailable, 'billing_change_unavailable'
        end
        if row.plan == Plans::BUSINESS && !StripeBilling.business_available?
          raise Unavailable, 'billing_business_unavailable'
        end
        raise Unavailable, 'billing_change_pending' if BillingLifecycle.pending_update?(subscription)
        # A schedule installed outside the app has another future writer. Do
        # not sell a change which that writer could silently undo at renewal.
        raise Unavailable, 'billing_change_unavailable' if SubscriptionSync.field(subscription, :schedule).present?

        yield subscription
      end
    end

    def plan_items(subscription, plan, seats)
      business = SubscriptionSync.item_for_price(subscription, StripeBilling.business_price_id)
      seat = SubscriptionSync.item_for_price(subscription, StripeBilling.price_id)
      desired_seats = plan == Plans::BUSINESS ? seats - 1 : seats

      [item_change(business, StripeBilling.business_price_id, plan == Plans::BUSINESS ? 1 : 0),
       item_change(seat, StripeBilling.price_id, desired_seats)].compact
    end

    def item_change(item, price, quantity)
      return if item.nil? && quantity.zero?
      return { id: SubscriptionSync.field(item, :id), deleted: true } if quantity.zero?
      return { id: SubscriptionSync.field(item, :id), quantity: } if item

      { price:, quantity: }
    end

    def update!(row, items, suffix)
      subscription = StripeBilling.client.v1.subscriptions.update(
        row.stripe_subscription_id,
        { items:, proration_behavior: 'always_invoice', payment_behavior: 'pending_if_incomplete' },
        { idempotency_key: change_key(row, suffix) }
      )
      result = BillingLifecycle.pending_update?(subscription) ? :pending : :updated
      Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)

      result
    end

    def write_packs!(row, subscription, quantity, proration:)
      StripeBilling.client.v1.subscriptions.update(
        row.stripe_subscription_id,
        { items: [item_change(pack_item(subscription), StripeBilling.api_pack_price_id, quantity)],
          proration_behavior: proration, payment_behavior: 'pending_if_incomplete' },
        { idempotency_key: change_key(row, "packs-#{quantity}-#{proration}") }
      )
    end

    def pack_item(subscription)
      SubscriptionSync.item_for_price(subscription, StripeBilling.api_pack_price_id)
    end

    def change_key(row, suffix)
      "tier-#{row.stripe_subscription_id}-#{row.updated_at.to_f}-#{suffix}"
    end
  end
end
