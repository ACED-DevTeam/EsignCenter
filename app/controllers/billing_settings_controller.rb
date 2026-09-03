# frozen_string_literal: true

# The account's own billing page (/settings/billing): what the subscription is
# doing right now, how many seats it covers, and the two doors to Stripe —
# Checkout to start the 14-day trial, and the Customer Portal to change the
# card, see invoices or cancel.
#
# Everything is decided about the BILLING account (Plans.billing_account), so a
# testing or linked child shows its parent's subscription and gets no buttons:
# the parent pays. The price, the quantity and the trial are server-owned —
# no request parameter is ever read for them.
#
# Stripe is never the app's source of truth here: Checkout and the Portal both
# come back through webhooks (Session 6 Phase A). The `return` action applies
# the subscription it can already see so the page tells the truth the second
# the user lands on it; the webhook says the same thing again, idempotently.
class BillingSettingsController < ApplicationController
  include LaunchGates

  # $10 per seat per month, one price for the whole product. The Stripe price
  # id is the authority on what is charged; this is only what we print.
  PRICE_PER_SEAT_USD = 10

  # Stripe statuses under which the subscription is well and truly over, and a
  # new Checkout is the right thing to offer.
  DEAD_STRIPE_STATUSES = %w[canceled incomplete_expired].freeze

  # The paid benefits the free-plan visitor is being sold, in the order they
  # are read. Each is a row of the entitlement matrix (lib/entitlements.rb).
  PAID_BENEFIT_KEYS = %w[
    billing_benefit_unlimited_documents
    billing_benefit_api
    billing_benefit_conditional_logic
    billing_benefit_reminders
    billing_benefit_branding
    billing_benefit_email_templates
  ].freeze

  before_action :require_billing_enabled!
  before_action :load_billing_account
  before_action :load_subscription

  rescue_from Stripe::StripeError do |e|
    ErrorReport.error(e, account_id: @billing&.id)

    redirect_to settings_billing_path, alert: I18n.t('billing_provider_unreachable')
  end

  def show
    @free_limits = Quotas.default_limits_for(@billing) if Plans.key_for(@billing) == Plans::FREE
    @paid_benefit_keys = PAID_BENEFIT_KEYS
    @price_per_seat = PRICE_PER_SEAT_USD
    @monthly_total = PRICE_PER_SEAT_USD * @seats_in_use
  end

  def checkout
    return redirect_to(settings_billing_path, alert: I18n.t('billing_already_subscribed')) if live_subscription?

    session = StripeBilling.client.v1.checkout.sessions.create(checkout_params, idempotency_key:)

    redirect_to session.url, allow_other_host: true, status: :see_other
  end

  def portal
    customer_id = @subscription&.stripe_customer_id

    return redirect_to(settings_billing_path, alert: I18n.t('billing_no_customer_yet')) if customer_id.blank?

    session = StripeBilling.client.v1.billing_portal.sessions.create(
      { customer: customer_id,
        configuration: StripeBilling.portal_configuration_id,
        return_url: settings_billing_url }
    )

    redirect_to session.url, allow_other_host: true, status: :see_other
  end

  # Checkout's success_url and cancel_url both land here. `return` is a Ruby
  # keyword, which Rails dispatches by name all the same.
  def return
    notice =
      if params[:cancelled].present?
        'billing_checkout_cancelled'
      elsif params[:session_id].present?
        apply_checkout_session(params[:session_id])
      end

    redirect_to settings_billing_path, notice: (I18n.t(notice) if notice)
  end

  private

  def load_billing_account
    @billing = Plans.billing_account(current_account)

    return head :not_found unless @billing.customer?

    authorize!(:manage, current_account)
  end

  def load_subscription
    @subscription = @billing.account_subscription
    @seats_in_use = Accounts.users_count(@billing)
    @seats_billed = [@seats_in_use, 1].max
    @state = @subscription&.access_state || 'free'
    # One trial per account, ever: the moment Stripe hands us a subscription
    # that has (or had) a trial, `trial_used_at` is stamped and never cleared.
    @trial_available = @subscription.nil? || @subscription.trial_used_at.nil?
    # A rake-granted row has no Stripe subscription behind it: the operator
    # owns it, and the buttons would only lie.
    @manual = @subscription&.status == 'manual'
    # A child account reads its parent's billing and cannot act on it.
    @read_only = @billing != current_account
    @parent_name = @read_only ? @billing.name : nil
    @actionable = !@read_only && !@manual
    @view_state = view_state
  end

  # What the page renders, which is the access state plus the three cases the
  # access state cannot express on its own: the parent pays, the operator
  # granted it by hand, or a subscription that is over versus one that never
  # existed.
  def view_state
    return 'manual' if @manual
    return @state unless @state == 'cancelled'

    @subscription.stripe_subscription_id.present? ? 'ended' : 'free'
  end

  # Paid right now, or holding a Stripe subscription that is still alive at
  # Stripe — either way a second Checkout would create a second subscription.
  def live_subscription?
    return true if Plans.paid_subscription?(@billing)
    return false if @subscription&.stripe_subscription_id.blank?

    DEAD_STRIPE_STATUSES.exclude?(@subscription.status)
  end

  def checkout_params
    params = {
      mode: 'subscription',
      customer: find_or_create_customer,
      client_reference_id: @billing.id.to_s,
      line_items: [{ price: StripeBilling.price_id, quantity: @seats_billed }],
      subscription_data: { metadata: { account_id: @billing.id } },
      payment_method_collection: 'always',
      allow_promotion_codes: false,
      success_url: "#{settings_billing_return_url}?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: settings_billing_return_url(cancelled: 1),
      automatic_tax: { enabled: false },
      customer_update: { address: 'auto', name: 'auto' },
      billing_address_collection: 'auto'
    }

    if @trial_available
      params[:subscription_data][:trial_period_days] = StripeBilling::TRIAL_PERIOD_DAYS
      params[:subscription_data][:trial_settings] = { end_behavior: { missing_payment_method: 'cancel' } }
    end

    params
  end

  # A double-clicked button inside the same minute must not create two Stripe
  # customers or two Checkout sessions.
  def idempotency_key
    "checkout-#{@billing.id}-#{Time.current.utc.strftime('%Y%m%d%H%M')}"
  end

  def find_or_create_customer
    # 'cancelled' is the only ACCESS_STATES value that means "no paid access";
    # the row exists purely to hold the Stripe customer id until Checkout comes
    # back, so it starts there with status 'none'.
    @subscription ||= @billing.create_account_subscription!(access_state: 'cancelled', status: 'none', quantity: 1)

    return @subscription.stripe_customer_id if @subscription.stripe_customer_id.present?

    customer = StripeBilling.client.v1.customers.create(
      { email: current_user.email, name: @billing.name, metadata: { account_id: @billing.id } },
      idempotency_key: "customer-#{idempotency_key}"
    )

    @subscription.update!(stripe_customer_id: customer.id)

    customer.id
  end

  # The Checkout session the browser just came back from, applied at once so
  # the page tells the truth before the webhook lands. It is only ever trusted
  # for THIS account: a session id belonging to somebody else is ignored, and
  # the webhook remains the authority either way. Returns the locale key of
  # what to say about it, or nil when there was nothing to apply.
  def apply_checkout_session(session_id)
    session = StripeBilling.client.v1.checkout.sessions.retrieve(session_id, { expand: ['subscription'] })

    return unless session.client_reference_id.to_s == @billing.id.to_s

    subscription = session.subscription

    return if subscription.blank? || subscription.try(:id).blank?

    @subscription ||= @billing.create_account_subscription!(access_state: 'cancelled', status: 'none', quantity: 1)
    @subscription.update!(stripe_subscription_id: @subscription.stripe_subscription_id.presence || subscription.id,
                          stripe_customer_id: @subscription.stripe_customer_id.presence || session.customer.to_s)

    StripeBilling::SubscriptionSync.apply!(@subscription, subscription)

    @subscription.access_state == 'trialing' ? 'billing_trial_started' : 'billing_subscription_active'
  end
end
