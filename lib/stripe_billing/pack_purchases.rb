# frozen_string_literal: true

module StripeBilling
  # Packs are full-price purchases, not prorations. A standalone invoice buys
  # only the additional units; after payment the recurring item changes with
  # proration disabled. The operation row is committed by TierChanges BEFORE
  # this module runs, so every external write has a stable retry identity.
  module PackPurchases
    METADATA_KEY = 'esigncenter_api_pack_purchase'

    module_function

    def process!(purchase, attempt_payment: true)
      row = purchase.account_subscription
      failure = nil
      result = Linker.with_account_lock(row) do
        purchase.reload
        next :updated if purchase.applied_at
        next :expired if purchase.closed_at

        begin
          process_locked!(purchase, row, attempt_payment:)
        rescue Stripe::StripeError => e
          # Keep any invoice id learned before the outage. Raising outside
          # the transaction preserves it; a DB failure still rolls back, but
          # metadata search + the operation's idempotency keys recover it.
          failure = e
          nil
        end
      end
      raise failure if failure

      result
    end

    def process_locked!(purchase, row, attempt_payment:)
      return settle_unavailable!(purchase) unless matching_subscription?(purchase, row)

      subscription = StripeBilling.subscription_for(purchase.stripe_subscription_id)
      raise TierChanges::Unavailable, 'billing_change_pending' if BillingLifecycle.pending_update?(subscription)

      SubscriptionSync.apply!(row, subscription)
      return settle_unavailable!(purchase) unless %w[active trialing].include?(row.access_state)

      assert_quantity!(purchase, row)
      invoice = find_or_create_invoice!(purchase, subscription)
      assert_invoice!(purchase, invoice)

      return apply_paid!(purchase, row, subscription, invoice) if field(invoice, :status) == 'paid'
      return close!(purchase) if field(invoice, :status) == 'void'
      return expire!(purchase, invoice) if purchase.expires_at <= Time.current

      invoice = finish_draft!(purchase, invoice) if field(invoice, :status) == 'draft'
      assert_invoice!(purchase, invoice)
      invoice = pay!(purchase, invoice) if attempt_payment && field(invoice, :status) == 'open'
      assert_invoice!(purchase, invoice)

      field(invoice, :status) == 'paid' ? apply_paid!(purchase, row, subscription, invoice) : :pending
    end

    def matching_subscription?(purchase, row)
      row.billing_customer? && row.stripe_subscription_id == purchase.stripe_subscription_id &&
        row.stripe_customer_id == purchase.stripe_customer_id
    end

    # Cancelling a subscription also closes an unpaid pack invoice. A paid
    # invoice cannot be silently discarded or restart the cancelled plan: it
    # becomes a durable operator-review debt, with its invoice id and amount.
    def settle_unavailable!(purchase)
      invoice = find_or_create_invoice!(purchase, nil, allow_create: false)
      unless invoice
        # Search can lag a successful invoice create whose response was lost.
        # Keep the operation recoverable: absence is not proof of no charge.
        OperatorAlert.deliver(
          subject: 'API pack invoice recovery needs operator review',
          body: "Account #{purchase.account_subscription.account_id} has an ineligible pack purchase " \
                "with an unknown invoice; operation #{purchase.operation_key}. No new invoice was created."
        )
        return :review
      end

      assert_invoice!(purchase, invoice)
      return close!(purchase) if field(invoice, :status) == 'void'
      return expire!(purchase, invoice) unless field(invoice, :status) == 'paid'

      purchase.update!(paid_at: purchase.paid_at || Time.current, closed_at: Time.current)
      OperatorAlert.deliver(
        subject: 'Paid API packs need operator review',
        body: "Account #{purchase.account_subscription.account_id} paid invoice #{purchase.stripe_invoice_id} " \
              "for #{purchase.amount_cents} cents, but its original subscription is no longer eligible. " \
              'No capacity or recurring charge was added. Review/refund the invoice; ' \
              "operation #{purchase.operation_key}."
      )
      :review
    end

    def assert_quantity!(purchase, row)
      return if %w[active trialing].include?(row.access_state) &&
                [purchase.previous_quantity, purchase.quantity].include?(row.api_pack_quantity)

      # An external change must not be overwritten by an old invoice. The
      # operation remains open and visible to reconciliation/operator alerts.
      raise TierChanges::Unavailable, 'billing_change_unavailable'
    end

    def find_or_create_invoice!(purchase, subscription, allow_create: true)
      invoices = StripeBilling.client.v1.invoices
      return invoices.retrieve(purchase.stripe_invoice_id) if purchase.stripe_invoice_id.present?

      # Search also recovers a successful create whose response or local save
      # was lost more than Stripe's 24-hour idempotency retention ago.
      found = invoices.search({ query: "metadata['#{METADATA_KEY}']:'#{purchase.operation_key}'", limit: 1 }).data.first
      return nil if found.nil? && !allow_create

      # Search is eventually consistent. Inside this safety window Stripe's
      # original idempotency key still prevents a second create; outside it,
      # an empty search is NOT proof that nothing was charged. Stop for an
      # operator rather than create again after key retention may have ended.
      raise TierChanges::Unavailable, 'billing_change_unavailable' if found.nil? && purchase.created_at <= 23.hours.ago

      invoice = found || invoices.create(invoice_params(purchase, subscription),
                                         { idempotency_key: key(purchase, 'invoice') })
      purchase.update!(stripe_invoice_id: field(invoice, :id))

      invoice
    end

    def invoice_params(purchase, subscription)
      params = { customer: purchase.stripe_customer_id, collection_method: 'charge_automatically',
                 auto_advance: false, pending_invoice_items_behavior: 'exclude',
                 automatic_tax: { enabled: false },
                 metadata: { METADATA_KEY => purchase.operation_key } }
      method = field(subscription, :default_payment_method)
      method = field(method, :id) unless method.is_a?(String)
      params[:default_payment_method] = method if method.present?

      params
    end

    def finish_draft!(purchase, invoice)
      lines = Array(field(field(invoice, :lines), :data))
      if lines.empty?
        StripeBilling.client.v1.invoice_items.create(
          { customer: purchase.stripe_customer_id, invoice: purchase.stripe_invoice_id,
            amount: purchase.amount_cents, currency: StripeBilling::PRICE_CURRENCY, discountable: false,
            description: "#{purchase.added_quantity} API packs (50 completions each)",
            metadata: { METADATA_KEY => purchase.operation_key } },
          { idempotency_key: key(purchase, 'item') }
        )
      elsif lines.size != 1 || field(field(lines.first, :metadata), METADATA_KEY) != purchase.operation_key
        raise TierChanges::Unavailable, 'billing_change_unavailable'
      end

      StripeBilling.client.v1.invoices.finalize_invoice(
        purchase.stripe_invoice_id, { auto_advance: false }, { idempotency_key: key(purchase, 'finalize') }
      )
    end

    def pay!(purchase, invoice)
      StripeBilling.client.v1.invoices.pay(
        purchase.stripe_invoice_id, { off_session: true }, { idempotency_key: key(purchase, 'pay') }
      )
    rescue Stripe::CardError
      # Authentication/declines leave an OPEN invoice that the customer can
      # pay through Stripe. No quantity moves on this branch.
      invoice
    end

    def assert_invoice!(purchase, invoice)
      own = field(invoice, :customer) == purchase.stripe_customer_id &&
            field(field(invoice, :metadata), METADATA_KEY) == purchase.operation_key
      correct_amount = field(invoice, :status) == 'draft' ||
                       (field(invoice, :currency) == StripeBilling::PRICE_CURRENCY &&
                        field(invoice, :total).to_i == purchase.amount_cents)
      return if own && correct_amount

      raise TierChanges::Unavailable, 'billing_change_unavailable'
    end

    def apply_paid!(purchase, row, subscription, invoice)
      paid_at = SubscriptionSync.timestamp(field(field(invoice, :status_transitions), :paid_at)) || Time.current
      purchase.update!(paid_at: purchase.paid_at || paid_at)
      if row.api_pack_quantity != purchase.quantity
        StripeBilling.client.v1.subscriptions.update(
          purchase.stripe_subscription_id,
          { items: [TierChanges.item_change(TierChanges.pack_item(subscription), StripeBilling.api_pack_price_id,
                                            purchase.quantity)], proration_behavior: 'none' },
          { idempotency_key: key(purchase, 'apply') }
        )
      end
      Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)
      raise TierChanges::Unavailable, 'billing_change_pending' unless row.api_pack_quantity == purchase.quantity

      purchase.update!(applied_at: Time.current)
      :updated
    end

    def expire!(purchase, invoice)
      # Never delete drafts: a lost delete response makes the invoice
      # undiscoverable and leaves the operation permanently open. Finalizing
      # without automatic collection, then voiding, preserves recovery truth.
      invoice = finish_draft!(purchase, invoice) if field(invoice, :status) == 'draft'
      assert_invoice!(purchase, invoice)
      StripeBilling.client.v1.invoices.void_invoice(
        purchase.stripe_invoice_id, {}, { idempotency_key: key(purchase, 'expire') }
      )
      close!(purchase)
    end

    def close!(purchase)
      purchase.update!(closed_at: Time.current)
      :expired
    end

    # The webhook is a trigger, never proof of payment. process! re-fetches
    # the invoice and verifies the customer, operation metadata and full total.
    def for_invoice_event(object)
      operation = object.dig('metadata', METADATA_KEY)
      return if operation.blank?

      ApiPackPurchase.find_by(operation_key: operation, stripe_customer_id: object['customer'])
    end

    def reconcile!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      ApiPackPurchase.open.find_each do |purchase|
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        process!(purchase, attempt_payment: false)
      rescue StandardError => e
        ErrorReport.error(e, account_id: purchase.account_subscription.account_id,
                             api_pack_purchase_id: purchase.id)
      end
    end

    def key(purchase, suffix)
      "api-pack-#{purchase.operation_key}-#{suffix}"
    end

    def field(object, name)
      SubscriptionSync.field(object, name)
    end
  end
end
