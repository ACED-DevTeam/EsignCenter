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
      config_rows + price_rows + portal_rows + webhook_rows
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

    def portal_rows
      if StripeBilling.portal_configuration_id.blank?
        return [row('portal', SKIP, 'not configured yet — run rake stripe:portal_configuration')]
      end

      configuration = StripeBilling.client.v1.billing_portal.configurations
                                   .retrieve(StripeBilling.portal_configuration_id)
      features = configuration.features

      [
        # Seats are the app's to change (Session 7), never a number a customer
        # types into Stripe: quantity editing must stay off.
        check('portal subscription_update off',
              features.subscription_update&.enabled != true || !adjustable_seats?(features),
              "enabled=#{features.subscription_update&.enabled}"),
        check('portal subscription_cancel on', features.subscription_cancel&.enabled == true,
              "enabled=#{features.subscription_cancel&.enabled}"),
        check('portal payment_method_update on', features.payment_method_update&.enabled == true,
              "enabled=#{features.payment_method_update&.enabled}"),
        check('portal invoice_history on', features.invoice_history&.enabled == true,
              "enabled=#{features.invoice_history&.enabled}")
      ]
    rescue Stripe::StripeError => e
      [row('portal', FAIL, "Stripe said: #{e.message}")]
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
            mode: 'at_period_end',
            proration_behavior: 'none',
            cancellation_reason: { enabled: true, options: CANCELLATION_REASONS }
          },
          subscription_update: { enabled: false },
          customer_update: { enabled: true, allowed_updates: %w[email address name] }
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
