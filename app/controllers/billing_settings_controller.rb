# frozen_string_literal: true

# The account's own billing page (/settings/billing): what the subscription is
# doing right now, how many seats it covers, Checkout to start the 14-day
# trial, and the Customer Portal to change the card, see invoices or cancel. D79 adds the
# app-owned plan and pack controls; the Portal never edits quantities.
#
# Everything is decided about the BILLING account (Plans.billing_account), so a
# testing or linked child shows its parent's subscription and gets no buttons:
# the parent pays. Checkout's seat count and trial are server-owned. The
# new controls accept only a plan key or pack count, never a Stripe price;
# TierChanges validates the request against the current subscription.
#
# Stripe is never the app's source of truth here: Checkout and the Portal both
# come back through webhooks (Session 6 Phase A). The `return` action applies
# the subscription it can already see so the page tells the truth the second
# the user lands on it; the webhook says the same thing again, idempotently.
class BillingSettingsController < ApplicationController
  include LaunchGates

  # Paid seats and extra Business seats share the same $10 price. Stripe's
  # price id decides the charge; the display constants, including Business's
  # base and packs, live together in lib/stripe_billing.rb.
  PRICE_PER_SEAT_USD = StripeBilling::PRICE_PER_SEAT_USD

  # The paid benefits the free-plan visitor is being sold, in the order they
  # are read. Each is a row of the entitlement matrix (lib/entitlements.rb).
  PAID_BENEFIT_KEYS = %w[
    billing_benefit_unlimited_in_app_documents
    billing_benefit_api
    billing_benefit_conditional_logic
    billing_benefit_reminders
    billing_benefit_branding
    billing_benefit_email_templates
  ].freeze

  before_action :require_billing_enabled!
  before_action :load_billing_account
  before_action :load_subscription
  before_action :require_own_billing!, only: %i[checkout portal return plan api_packs]
  before_action :refuse_moved_away_account!, only: %i[checkout portal return plan api_packs]
  before_action :refuse_pending_deletion!, only: %i[checkout portal plan api_packs]
  before_action :refuse_suspended_spending!, only: %i[plan api_packs]

  helper_method :billing_date

  # Stripe could not be reached — or its answer could not be used, in one of
  # three ways: a customer subscription list that stopped short of the end
  # means "no live subscription" cannot be concluded and nothing is sold on
  # it; and a duplicate subscription found on the way in whose refund the app
  # refuses to make on its own (more payments than it returns unattended, an
  # invoice that does not add up) stops this request too. That last one is a
  # decision for a person, not an outage, and the customer is told the same
  # neutral sentence rather than meeting a 500 page: the duplicate is
  # cancelled, the debt is recorded on their row and the operator has already
  # been paged, so the one thing left to get right here is that nobody sells
  # them a subscription on top of it.
  rescue_from Stripe::StripeError, StripeBilling::ListIncomplete, StripeBilling::Linker::RefundUnavailable do |e|
    # First, before anything else: if the failure carries a duplicate whose
    # money is owed, write that down. The whole checkout action runs inside
    # one row lock, so the note the Linker made was rolled back with
    # everything else — and this handler is the first place that runs after
    # the rollback. Without it the only record of the debt would be the alert
    # and the marker at Stripe.
    StripeBilling::Linker.stamp_owed_refund!(@subscription, e)

    ErrorReport.error(e, account_id: @billing&.id)

    redirect_to settings_billing_path, alert: I18n.t('billing_provider_unreachable')
  end

  # Another worker held this account's row for longer than the Linker's lock
  # timeout (a webhook mid-flight, a second tab): a minute later it is free.
  rescue_from ActiveRecord::LockWaitTimeout do |e|
    ErrorReport.warning("billing lock wait timed out: #{e.message}", account_id: @billing&.id)

    redirect_to settings_billing_path, alert: I18n.t('billing_provider_unreachable')
  end

  rescue_from StripeBilling::TierChanges::Unavailable do |e|
    redirect_to settings_billing_path, alert: I18n.t(e.message)
  end

  def show
    @free_limits = Quotas.default_limits_for(@billing) if Plans.key_for(@billing) == Plans::FREE
    @limits_overridden = AccountLimitOverride.exists?(account_id: @billing.id)
    @paid_benefit_keys = PAID_BENEFIT_KEYS
    @price_per_seat = PRICE_PER_SEAT_USD
  end

  # The whole decision — is there already a subscription, which Stripe
  # customer is this, does Stripe know of a live subscription we do not, and
  # only then a Checkout Session — is ONE step under the account's row lock.
  # Split up, two clicks (or a click and a webhook) could each pass the
  # checks and sell the same account two subscriptions.
  def checkout
    return refuse_checkout if live_subscription?

    ensure_subscription_row!

    session = StripeBilling::Linker.with_account_lock(@subscription) do
      # The lock re-reads the row: whatever a concurrent worker wrote wins.
      next nil if live_subscription?

      customer_id = find_or_create_customer

      # Our own row is not the only witness: a Checkout completed in a tab we
      # never heard back from left a subscription at Stripe all the same.
      next nil if StripeBilling::Linker.link_live_subscriptions!(@subscription, customer_id)

      # The trial question is asked AGAIN here, on the row the lock re-read,
      # and never on the answer the before_action computed when the request
      # came in (Review 6 X5). Between those two moments a webhook can stamp
      # `trial_used_at` — the customer's first Checkout completing in another
      # tab — and the stale answer sold them a SECOND 14-day trial: the
      # server's own "one trial per account, ever" rule, broken by the only
      # door that can sell one.
      @trial_available = trial_available?

      create_checkout_session(customer_id)
    end

    return refuse_checkout if session.nil?

    redirect_to session.url, allow_other_host: true, status: :see_other
  end

  def plan
    result = StripeBilling::TierChanges.change_plan!(@subscription, params[:plan].to_s)

    redirect_to settings_billing_path,
                notice: I18n.t(result == :pending ? 'billing_change_pending' : 'billing_plan_updated')
  end

  def api_packs
    result = StripeBilling::TierChanges.change_packs!(@subscription, params[:quantity].to_s)

    redirect_to settings_billing_path,
                notice: I18n.t({ pending: 'billing_change_pending', expired: 'billing_pack_purchase_expired',
                                 review: 'billing_pack_purchase_review' }
                                .fetch(result, 'billing_api_packs_updated'))
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
    flash_for =
      if params[:cancelled].present?
        { notice: I18n.t('billing_checkout_cancelled') }
      elsif params[:session_id].present?
        apply_checkout_session(params[:session_id])
      else
        {}
      end

    redirect_to settings_billing_path, flash: flash_for
  end

  # Every date on this page, in the account's own timezone and language, like
  # every other settings page: a trial that ends at 02:00 UTC is still
  # tomorrow for a customer in New York.
  def billing_date(time)
    return if time.blank?

    zone = current_account.timezone.presence || 'UTC'

    l(time.in_time_zone(zone).to_date, format: :long, locale: current_account.locale)
  end

  private

  def load_billing_account
    @billing = Plans.billing_account(current_account)

    return head :not_found unless @billing.customer?

    # `:billing`, not `:manage`: a suspended account has lost every other
    # door on its own account row and must keep this one — it is the page
    # that settles the payment (lib/ability.rb).
    authorize!(:billing, current_account)
  end

  # Reading somebody else's billing page is allowed (a child is told who
  # pays); acting on it is not. Without this the buttons were the only thing
  # stopping a child's admin from buying on the parent, opening the parent's
  # Customer Portal — card, invoices, cancellation — or applying a Checkout
  # session to the parent's row.
  def require_own_billing!
    return head :not_found unless @billing == current_account

    return unless @manual

    redirect_to settings_billing_path, alert: I18n.t('billing_managed_by_operator')
  end

  # An account that was archived because its only member joined another team
  # (Accounts::MoveUser) is finished, and none of the three acting doors may be
  # used on it (review 7, D50 D3).
  #
  # `return` is the one that matters. A Checkout started before the move and
  # completed after it comes back to this controller carrying a session id,
  # and `apply_checkout_session` would take that session at face value and
  # hand a dead account a live subscription — the same hole the webhook side
  # closes, through the other door. The webhook barrier is what makes the
  # money safe; this makes the browser say so in a sentence instead of
  # applying it, or falling over somewhere further down.
  #
  # Reading is left alone: `show` still renders, so anybody who can still get
  # here sees the state of the subscription rather than a wall. Only the three
  # doors that ACT are shut, and each is shut with the same sentence.
  def refuse_moved_away_account!
    return unless StripeBilling::SubscriptionSync.moved_away?(@billing)

    redirect_to settings_billing_path, alert: I18n.t('billing_account_moved_away')
  end

  # An account whose deletion has been asked for may not start paying again
  # (review 7, C1). The deletion cancelled the subscription and the mail said
  # "you will not be charged again"; buying a new one through this page kept
  # that promise broken AND made the account unpurgeable — on day 90 the purge
  # refuses to destroy an account that is still being charged, releases its
  # claim and pages the operator, and does the same every night after that,
  # while the card keeps being billed for an account nobody can write to.
  #
  # Both doors that could restart the money are shut with one sentence that
  # says what to do instead: cancel the deletion first. `show` still renders
  # (with the same sentence in place of the buttons), and the Checkout return
  # is deliberately NOT shut: a session completed a moment before the deletion
  # request has already created a subscription at Stripe, and refusing to
  # record it would leave it billing with nothing in the app pointing at it —
  # the webhook writes it down either way.
  def refuse_pending_deletion!
    return unless current_account.pending_deletion?

    redirect_to settings_billing_path, alert: I18n.t('billing_refused_pending_deletion')
  end

  # A suspended account keeps the doors that settle what it owes (checkout,
  # portal) and loses the ones that add to it. Stripe's own state only covers
  # a payment suspension; an operator suspension can sit on a subscription
  # Stripe still calls active, and a frozen account must not upgrade to
  # Business or buy API packs it cannot use.
  def refuse_suspended_spending!
    return unless AccountStates.read_only?(current_account)

    operator = AccountStates.suspension_candidates(current_account).filter_map(&:suspension_reason).first == 'operator'

    redirect_to settings_billing_path,
                alert: I18n.t(operator ? 'account_suspended_banner_operator' : 'billing_refused_suspended')
  end

  def load_subscription
    @subscription = @billing.account_subscription
    # Occupancy: the people who hold a seat plus the invitations holding one
    # for somebody who has not arrived yet (Session 7 Phase B). The pending
    # half is called out separately, because it is the half a customer can
    # cancel to get a seat back.
    @seats_in_use = Accounts.users_count(@billing)
    @pending_invites_count = AccountInvite.pending.where(account_id: Accounts.seat_account_ids(@billing)).count
    @seats_billed = [@seats_in_use, 1].max
    @state = @subscription&.access_state || 'free'
    # One trial per account, ever: the moment Stripe hands us a subscription
    # that has (or had) a trial, `trial_used_at` is stamped and never cleared.
    # What the PAGE renders; the Checkout door asks again under the row lock.
    @trial_available = trial_available?
    # A rake-granted row has no Stripe subscription behind it: the operator
    # owns it, and the buttons would only lie.
    @manual = @subscription&.status == 'manual'
    # A child account reads its parent's billing and cannot act on it.
    @read_only = @billing != current_account
    @parent_name = @read_only ? @billing.name : nil
    # The deletion is scheduled: the page says so where the buy button was,
    # rather than offering a button the server would only turn away.
    @pending_deletion = current_account.pending_deletion?
    @actionable = !@read_only && !@manual && !@pending_deletion
    @view_state = view_state
    # Stripe's own word for the subscription, not our access state. A trial
    # the customer has already cancelled reads as `canceling` here — the
    # cancellation outranks the status in `access_state_for`, whether Stripe
    # expressed it as the period-end flag or as a `cancel_at` date — while
    # Stripe is still running it as a trial and has charged nothing. The card
    # has to say "no charge is coming" rather than quote a monthly price they
    # will never pay.
    @in_trial = @subscription&.stripe_status == 'trialing'
    # What Stripe actually bills: the quantity frozen at Checkout, which is
    # not the same as the number of people in the account today. The page
    # quotes the invoice, and says the difference out loud.
    @billed_seats = @subscription&.quantity
    @monthly_total = @subscription ? @subscription.monthly_amount_usd : PRICE_PER_SEAT_USD * @seats_billed
  end

  def trial_available?
    @subscription.nil? || @subscription.trial_used_at.nil?
  end

  # What the page renders, which is the access state plus the three cases the
  # access state cannot express on its own: the parent pays, the operator
  # granted it by hand, or a subscription that is over versus one that never
  # existed.
  def view_state
    return 'manual' if @manual
    return @state unless @state == 'cancelled'
    # `incomplete` is not paid access, but the subscription is alive at Stripe
    # and the server refuses a second Checkout for it. The page has to ask the
    # same question the controller does, or it offers a button that can only
    # be turned away.
    return 'incomplete' if live_subscription?

    @subscription.stripe_subscription_id.present? ? 'ended' : 'free'
  end

  # Paid right now, or holding a Stripe subscription that is still alive at
  # Stripe — either way a second Checkout would create a second subscription.
  # Read off the row in hand (freshly reloaded when asked under the lock);
  # the Linker then asks Stripe itself before anything is sold.
  def live_subscription?
    return false if @subscription.nil?

    Plans::PAID_ACCESS_STATES.include?(@subscription.access_state) ||
      StripeBilling::Linker.holds_live_subscription?(@subscription)
  end

  # Three honest sentences where there used to be one. "You already have an
  # active subscription" is simply untrue for the two states that reach here
  # without one: an `incomplete` subscription whose first payment never
  # finished, and a `suspended` account frozen for an unpaid invoice. Both
  # need a different next step, so both get their own sentence.
  def refuse_checkout
    redirect_to settings_billing_path, alert: I18n.t(refusal_key)
  end

  def refusal_key
    case @view_state
    when 'incomplete' then 'billing_refused_incomplete'
    when 'suspended' then 'billing_refused_suspended'
    else 'billing_already_subscribed'
    end
  end

  def create_checkout_session(customer_id)
    StripeBilling.client.v1.checkout.sessions.create(checkout_params(customer_id), idempotency_key:)
  rescue Stripe::IdempotencyError
    # The same key with a different body: seats changed between two clicks.
    # One retry with a fresh key, rather than telling the customer Stripe is
    # down when it is answering perfectly well.
    StripeBilling.client.v1.checkout.sessions.create(
      checkout_params(customer_id), idempotency_key: "#{idempotency_key}-#{SecureRandom.hex(4)}"
    )
  end

  def checkout_params(customer_id)
    params = {
      mode: 'subscription',
      customer: customer_id,
      client_reference_id: @billing.id.to_s,
      line_items: [{ price: StripeBilling.price_id, quantity: @seats_billed }],
      # Namespaced, because this tag is half of "is this subscription ours"
      # (StripeBilling::SubscriptionPolicy) and a bare `account_id` is a name
      # another product on the same Stripe account would use too.
      subscription_data: { metadata: { account_tag_key => @billing.id } },
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
  # customers or two Checkout sessions. The seats and the trial are part of
  # the key: reusing it for a DIFFERENT body is what Stripe calls an
  # idempotency error, and that is not an outage.
  def idempotency_key
    "checkout-#{@billing.id}-#{@seats_billed}-#{@trial_available}-#{Time.current.utc.strftime('%Y%m%d%H%M')}"
  end

  # 'cancelled' is the only ACCESS_STATES value that means "no paid access";
  # the row exists purely to hold the Stripe customer id until Checkout comes
  # back, so it starts there with status 'none'. INSERT first and SELECT on
  # conflict (create_or_find_by!): two clicks race for it, account_id is
  # unique, and a SELECT-then-INSERT loses that race with a 500.
  def ensure_subscription_row!
    return @subscription if @subscription

    @subscription = AccountSubscription.create_or_find_by!(account: @billing) do |row|
      row.access_state = 'cancelled'
      row.status = 'none'
      row.quantity = 1
    end
  end

  # One Stripe customer per account, ever. Stripe is asked first whether a
  # customer tagged with this account already exists (a checkout that
  # rolled back after Stripe answered left one behind); only then is one
  # created, with a body that does not depend on who clicked and an
  # idempotency key that is the account itself. An idempotency refusal
  # ("same key, different body") means the customer exists: it is searched
  # for and adopted, never re-created under a made-up key.
  def find_or_create_customer
    return @subscription.stripe_customer_id if @subscription.stripe_customer_id.present?

    customer = find_customer || create_customer

    @subscription.update!(stripe_customer_id: customer.id)

    customer.id
  end

  def find_customer
    StripeBilling.client.v1.customers.search(
      { query: "metadata['#{account_tag_key}']:'#{@billing.id}'", limit: 1 }
    ).data.first
  end

  def create_customer
    StripeBilling.client.v1.customers.create(
      { email: billing_contact_email, name: @billing.name, metadata: { account_tag_key => @billing.id } },
      idempotency_key: "customer-account-#{@billing.id}"
    )
  rescue Stripe::IdempotencyError
    find_customer || raise
  end

  # One name for "this Stripe object belongs to account N", written on the
  # customer and on the subscription and read back by SubscriptionPolicy.
  def account_tag_key
    StripeBilling::SubscriptionPolicy::ACCOUNT_TAG_KEY
  end

  # The account's first active admin, not whoever is clicking: the customer
  # create body has to be the same on every attempt.
  def billing_contact_email
    @billing.users.active.admins.order(:id).first&.email || current_user.email
  end

  # The Checkout session the browser just came back from, applied at once so
  # the page tells the truth before the webhook lands.
  #
  # The session id in the query string proves nothing on its own — it is a
  # bookmarkable URL — so the session has to BE this account's completed
  # subscription purchase on the customer this account's row already holds
  # (Checkout created that row and that customer before the session ever
  # existed, so "no row" or "another customer" is not ours to act on). The
  # subscription it carries then goes through the Linker like every other
  # one: if the row already holds a different live subscription, this one is
  # the duplicate and is cancelled rather than written over the one that is
  # charging the card. Returns what to flash.
  def apply_checkout_session(session_id)
    session = StripeBilling.client.v1.checkout.sessions.retrieve(session_id, { expand: ['subscription'] })
    subscription_id = session.subscription.try(:id) || session.subscription.presence

    return unmatched_checkout(session_id) unless ours?(session) && subscription_id.present?

    flash_for_outcome(StripeBilling::Linker.link_and_apply!(@subscription, subscription_id))
  rescue Stripe::InvalidRequestError => e
    # A session id Stripe has never heard of is not an outage (S6, S4): it is a
    # bookmarked, mistyped or made-up return URL, and this is the same answer
    # as a session that turns out to belong to somebody else. Letting it fall
    # through to the Stripe handler told the customer the payment provider was
    # unreachable and paged us with an ErrorReport.error for a stale bookmark.
    raise unless e.code.to_s == 'resource_missing'

    unmatched_checkout(session_id)
  end

  # A Checkout session this app can act on: a completed subscription purchase,
  # for this billing account, on exactly the customer this row holds, whose
  # subscription — if our Checkout tagged it at all — is tagged for us.
  def ours?(session)
    session.mode.to_s == 'subscription' &&
      session.status.to_s == 'complete' &&
      session.client_reference_id.to_s == @billing.id.to_s &&
      known_customer?(session.customer) &&
      tagged_for_us?(session.subscription)
  end

  def known_customer?(customer)
    customer_id = customer.is_a?(String) ? customer : customer.try(:id)

    @subscription.present? && @subscription.stripe_customer_id.present? &&
      @subscription.stripe_customer_id == customer_id.to_s
  end

  def tagged_for_us?(subscription)
    tag = StripeBilling::SubscriptionPolicy.tagged_account_id(subscription)

    tag.blank? || tag == @billing.id.to_s
  end

  def unmatched_checkout(session_id)
    ErrorReport.warning("checkout session #{session_id} could not be matched to account #{@billing.id}",
                        account_id: @billing.id)

    { alert: I18n.t('billing_checkout_unmatched') }
  end

  def flash_for_outcome(outcome)
    return { alert: I18n.t('billing_checkout_unmatched') } if outcome.verdict == :foreign_ignored
    return { notice: duplicate_notice(outcome.refund) } if outcome.verdict == :duplicate_cancelled

    state = @subscription.reload.access_state

    if state == 'trialing'
      return { notice: I18n.t('billing_trial_started', trial_days: StripeBilling::TRIAL_PERIOD_DAYS) }
    end
    # Two paid states that are NOT "your subscription is active", and saying
    # so used to contradict the state card the customer was looking at. A
    # subscription whose first payment failed is past_due before it ever
    # charged; one Stripe hands back already set to cancel ends at the period
    # end. Each says what it is and where to fix it.
    return { alert: I18n.t('billing_checkout_past_due') } if state == 'past_due'
    return { notice: I18n.t('billing_checkout_canceling') } if state == 'canceling'
    # An incomplete or already-cancelled subscription is not "active": the
    # state card says what happened, and a green sentence would contradict it.
    return {} unless Plans::PAID_ACCESS_STATES.include?(state)

    { notice: I18n.t('billing_subscription_active') }
  end

  # The truth about the money: a duplicate that had already charged the card
  # was refunded, and the customer is told how much.
  def duplicate_notice(refund)
    return I18n.t('billing_duplicate_cancelled') if refund.nil?

    I18n.t('billing_duplicate_refunded', amount: refund.formatted_amount)
  end
end
