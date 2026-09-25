# frozen_string_literal: true

module StripeBilling
  # What `rake stripe:check` actually asserts, kept out of the rake file so it
  # can be tested. Every check answers one question about the LIVE Stripe
  # account: is the thing the app assumes still true there? A dashboard is a
  # place where a well-meaning change (turn quantity editing back on, swap the
  # price) silently breaks the product, and this is how that gets caught.
  module Checks
    PASS = 'PASS'
    FAIL = 'FAIL'
    WARN = 'WARN'
    SKIP = 'SKIP'

    MANIFEST_VERSION = '1'

    CANCELLATION_REASONS = %w[
      too_expensive missing_features switched_service unused too_complex low_quality other
    ].freeze

    WEBHOOK_PATH = '/stripe/webhooks'

    # How a customer's own cancellation must behave, and the only customer
    # details they may edit. Both are written by
    # `rake stripe:portal_configuration` (portal_params below) and both are
    # asserted back out of the live configuration, because a dashboard is a
    # place where somebody changes one of them by hand:
    #
    #   * `at_period_end` — a customer who cancels keeps the month they have
    #     already paid for. `immediately` would end it on the spot, and the
    #     app's own state table (`canceling` keeps the paid features on)
    #     would be describing something that no longer happens;
    #   * `none` — no mid-cycle credit. The product's rule is that a
    #     reduction is never refunded (D43), so a portal that prorated a
    #     cancellation would hand back money the app never accounts for;
    #   * the allowed updates — email, address and name are the invoice
    #     details that are the customer's to correct. `address` in particular
    #     has to stay: Checkout collects it (`customer_update: address auto`)
    #     and a customer who moves has no other way to fix an invoice.
    CANCEL_MODE = 'at_period_end'
    CANCEL_PRORATION = 'none'
    ALLOWED_CUSTOMER_UPDATES = %w[email address name].freeze

    WEBHOOK_EVENTS = %w[
      checkout.session.completed
      customer.subscription.created
      customer.subscription.updated
      customer.subscription.deleted
      customer.subscription.paused
      customer.subscription.resumed
      customer.subscription.trial_will_end
      invoice.paid
      invoice.payment_failed
      invoice.payment_action_required
    ].freeze

    module_function

    def rows
      config_rows + price_rows + optional_price_rows + portal_rows + webhook_rows
    end

    def failed?(rows)
      rows.any? { |row| row[:result] == FAIL }
    end

    def config_rows
      StripeBilling.config_status.map do |name, state|
        if !state[:present]
          row(name, FAIL, 'not set')
        elsif !state[:shape_ok]
          row(name, FAIL, "does not start with #{state[:prefix]}")
        else
          row(name, PASS, "set (#{state[:prefix]}…)")
        end
      end
    end

    def price_rows
      return [row('price', FAIL, 'STRIPE_PRICE_ID is not set')] if StripeBilling.price_id.blank?

      price = StripeBilling.client.v1.prices.retrieve(StripeBilling.price_id)

      [
        livemode_check('price livemode', price),
        check('price active', price.active == true, "active=#{price.active}"),
        check('price currency', price.currency == StripeBilling::PRICE_CURRENCY, price.currency),
        check('price amount', price.unit_amount == StripeBilling::PRICE_UNIT_AMOUNT,
              "#{price.unit_amount} (expected #{StripeBilling::PRICE_UNIT_AMOUNT})"),
        check('price interval', price.recurring&.interval == StripeBilling::PRICE_INTERVAL &&
                                price.recurring&.interval_count == 1,
              "#{price.recurring&.interval_count} #{price.recurring&.interval}")
      ]
    rescue Stripe::StripeError => e
      [row('price', FAIL, "Stripe said: #{e.message}")]
    end

    # Missing optional prices are honest unavailable products, not a broken
    # Paid deployment. Configured prices must match the D79 recurring amount.
    def optional_price_rows
      rows = [[StripeBilling.business_price_id, 'Business', StripeBilling::BUSINESS_BASE_USD],
              [StripeBilling.api_pack_price_id, 'API pack',
               StripeBilling::API_PACK_USD]].flat_map do |id, name, dollars|
        next [row("#{name} price", SKIP, 'not configured — unavailable to purchase')] if id.blank?

        optional_price_checks(id, name, dollars)
      end
      prices = [StripeBilling.price_id, StripeBilling.business_price_id, StripeBilling.api_pack_price_id].compact_blank
      rows << check('plan and pack price ids distinct', prices.uniq.size == prices.size, 'one price per product') if
        prices.size > 1

      rows
    end

    def optional_price_checks(id, name, dollars)
      price = StripeBilling.client.v1.prices.retrieve(id)

      [livemode_check("#{name} price livemode", price),
       check("#{name} price active", price.active == true, "active=#{price.active}"),
       check("#{name} price currency", price.currency == StripeBilling::PRICE_CURRENCY, price.currency),
       check("#{name} price amount", price.unit_amount == dollars * 100,
             "#{price.unit_amount} (expected #{dollars * 100})"),
       check("#{name} price interval", price.recurring&.interval == StripeBilling::PRICE_INTERVAL &&
                                      price.recurring&.interval_count == 1, 'monthly recurring')]
    rescue Stripe::StripeError => e
      [row("#{name} price", FAIL, "Stripe said: #{e.message}")]
    end

    def portal_rows
      if StripeBilling.portal_configuration_id.blank?
        return [row('portal', SKIP, 'not configured yet — run rake stripe:portal_configuration')]
      end

      configuration = StripeBilling.client.v1.billing_portal.configurations
                                   .retrieve(StripeBilling.portal_configuration_id)
      features = configuration.features

      [
        livemode_check('portal livemode', configuration),
        check('portal configuration active', SubscriptionSync.field(configuration, :active) == true,
              "active=#{SubscriptionSync.field(configuration, :active).inspect}"),
        # Seats are the app's to change (Session 7), never a number a customer
        # types into Stripe: quantity editing must stay off.
        check('portal subscription_update off',
              features.subscription_update&.enabled != true || !adjustable_seats?(features),
              "enabled=#{features.subscription_update&.enabled}"),
        *cancel_rows(features),
        check('portal customer_update matches the manifest', allowed_updates_match?(features),
              "allowed_updates=#{allowed_updates(features).join(', ').presence || '(none)'} " \
              "(expected #{ALLOWED_CUSTOMER_UPDATES.join(', ')})"),
        check('portal payment_method_update on', features.payment_method_update&.enabled == true,
              "enabled=#{features.payment_method_update&.enabled}"),
        check('portal invoice_history on', features.invoice_history&.enabled == true,
              "enabled=#{features.invoice_history&.enabled}")
      ]
    rescue Stripe::StripeError => e
      [row('portal', FAIL, "Stripe said: #{e.message}")]
    end

    # The cancel WALK, not just the button: that a cancellation is offered at
    # all, how it lands, and what it does to the money (X7a). Read through
    # `field`, which answers nil for a setting the live configuration simply
    # does not carry — asking a Stripe object for a property it has never
    # heard of raises.
    def cancel_rows(features)
      [
        check('portal subscription_cancel on', cancel_setting(features, :enabled) == true,
              "enabled=#{cancel_setting(features, :enabled)}"),
        check('portal cancel at period end', cancel_setting(features, :mode) == CANCEL_MODE,
              "mode=#{cancel_setting(features, :mode) || '(none)'} (expected #{CANCEL_MODE})"),
        check('portal cancel proration off', cancel_setting(features, :proration_behavior) == CANCEL_PRORATION,
              "proration_behavior=#{cancel_setting(features, :proration_behavior) || '(none)'} " \
              "(expected #{CANCEL_PRORATION})")
      ]
    end

    # Exactly the manifest's list, no more and no less — order does not
    # matter, membership does. Less than the manifest means a customer cannot
    # fix an invoice detail the app expects them to fix (a missing `address`
    # is the one that bites, because Checkout collects one); more than it
    # means the portal is doing something nobody wrote down.
    def allowed_updates_match?(features)
      customer_update = SubscriptionSync.field(features, :customer_update)

      SubscriptionSync.field(customer_update, :enabled) == true &&
        allowed_updates(features).sort == ALLOWED_CUSTOMER_UPDATES.sort
    end

    def allowed_updates(features)
      customer_update = SubscriptionSync.field(features, :customer_update)

      Array(SubscriptionSync.field(customer_update, :allowed_updates)).map(&:to_s)
    end

    def cancel_setting(features, name)
      SubscriptionSync.field(SubscriptionSync.field(features, :subscription_cancel), name)
    end

    # Seats belong to the app (Session 7 owns the flow); a portal that lets a
    # customer type their own quantity would put two writers on one number.
    def adjustable_seats?(features)
      Array(features.subscription_update&.products).any? do |product|
        quantity = product['adjustable_quantity']

        quantity.present? && quantity['enabled'] != false
      end
    end

    # A missing endpoint is a warning, not a failure: the dev stack forwards
    # with `stripe listen` and has no registered endpoint at all.
    def webhook_rows
      endpoints = StripeBilling.client.v1.webhook_endpoints.list({ limit: 100 }).data
      ours = endpoints.select { |endpoint| endpoint.url.to_s.end_with?(WEBHOOK_PATH) }

      return [row('webhook endpoint', WARN, "none of #{endpoints.size} endpoint(s) targets #{WEBHOOK_PATH}")] if
        ours.empty?

      ours.map do |endpoint|
        missing = WEBHOOK_EVENTS - Array(endpoint.enabled_events)
        listening_to_all = Array(endpoint.enabled_events).include?('*')

        check("webhook endpoint #{endpoint.url}", missing.empty? || listening_to_all,
              missing.empty? || listening_to_all ? "status=#{endpoint.status}" : "missing #{missing.join(', ')}")
      end
    rescue Stripe::StripeError => e
      [row('webhook endpoint', WARN, "Stripe said: #{e.message}")]
    end

    def portal_params
      {
        business_profile: { headline: 'EsignCenter' },
        features: {
          invoice_history: { enabled: true },
          payment_method_update: { enabled: true },
          subscription_cancel: {
            enabled: true,
            mode: CANCEL_MODE,
            proration_behavior: CANCEL_PRORATION,
            cancellation_reason: { enabled: true, options: CANCELLATION_REASONS }
          },
          subscription_update: { enabled: false },
          customer_update: { enabled: true, allowed_updates: ALLOWED_CUSTOMER_UPDATES }
        },
        default_return_url: billing_page_url,
        metadata: { esigncenter_manifest_version: MANIFEST_VERSION }
      }
    end

    # Where Stripe sends a customer when they close the portal: this app's own
    # billing page, built from the same APP_URL/HOST the rest of the app uses.
    def billing_page_url
      options = Docuseal.default_url_options
      port = options[:port].presence && [80, 443].exclude?(options[:port]) ? ":#{options[:port]}" : ''

      "#{options[:protocol] || 'https'}://#{options[:host]}#{port}/settings/billing"
    end

    # A test-mode object under a live key (or the reverse) is "No such price"
    # at the first Checkout. Stripe says which mode every object lives in.
    def livemode_check(name, object)
      livemode = SubscriptionSync.field(object, :livemode)

      check(name, livemode == PriceGuard.expected_livemode,
            "livemode=#{livemode.inspect} (secret key is #{PriceGuard.key_mode_label})")
    end

    def check(name, condition, detail)
      row(name, condition ? PASS : FAIL, detail)
    end

    def row(name, result, detail)
      { name:, result:, detail: }
    end

    def table(rows)
      width = rows.map { |r| r[:name].length }.max.to_i

      rows.map { |r| format("%-<name>#{width}s  %-4<result>s  %<detail>s", name: r[:name], **r) }.join("\n")
    end
  end
end
