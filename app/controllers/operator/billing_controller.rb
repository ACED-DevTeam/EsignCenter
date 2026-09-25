# frozen_string_literal: true

module Operator
  # Money: what the platform is billing right now, what Stripe has been trying
  # to tell us, and what last night's reconciliation found.
  #
  # Every number on this page is computed from OUR rows, which is not the same
  # thing as Stripe's ledger — a subscription cancelled ten minutes ago is
  # still `active` here until the webhook lands. The page says so out loud
  # rather than pretending otherwise: Stripe is the source of truth, this is
  # what the app believes.
  class BillingController < BaseController
    # The access states that are actually COLLECTING money, and the reason
    # each is in or out:
    #
    #   active     — being charged this month. In.
    #   past_due   — the renewal is late and Stripe is still retrying it. In:
    #                the seat is still sold and most dunning recovers; leaving
    #                it out would make a payment blip look like churn.
    #   canceling  — cancels at period end, so this period IS still paid. In.
    #   trialing   — nothing has been charged yet. OUT: counting a trial as
    #                revenue is how a free month becomes a forecast.
    #   suspended  — Stripe has given up (`unpaid`/`paused`). OUT.
    #   cancelled  — over. OUT.
    PAYING_STATES = %w[active past_due canceling].freeze

    # And the second half of the same question, because the access state is
    # not enough on its own (session 10, seam M1). Cancelling a subscription
    # that is still in its TRIAL from Stripe's Customer Portal sets a
    # `cancel_at` date rather than the period-end flag, and the app reads that
    # date as `canceling` — a paying state — while Stripe still calls the
    # subscription `trialing` and has still charged nobody. Booking that as
    # revenue for the rest of the trial is exactly the fiction the constant
    # above was written to prevent, so every MONEY query asks Stripe's own
    # word as well: a row Stripe calls a trial is a trial, whatever access
    # state we gave it.
    #
    # `IS DISTINCT FROM` rather than `!=` because the column is null for every
    # row that never came from Stripe at all — a comp, an operator's manual
    # grant — and a null must read as "not a trial" rather than dropping the
    # row out of the comparison altogether.
    TRIALING_STATUS = 'trialing'

    # And the rows that are in a paying state but are not paying anybody:
    # a comp the operator granted by hand (`status` 'manual', with or without
    # an expiry date). They are counted separately, on purpose — a comped
    # account looks exactly like a paying one in every other column.
    COMP_STATUS = 'manual'

    # One sentence per reason the locked adoption can refuse. The Linker
    # raises the REASON, never the words: which sentence a person reads is
    # this surface's business, not the money code's.
    ADOPTION_REFUSALS = {
      no_subscription: 'operator_refused_adopt_no_subscription',
      already_holds_this: 'operator_refused_adopt_holds_this',
      already_holds_other: 'operator_refused_adopt_already_linked',
      not_ours: 'operator_refused_adopt_not_ours',
      tagged_elsewhere: 'operator_refused_adopt_tagged_elsewhere',
      no_customer: 'operator_refused_adopt_no_customer',
      customer_mismatch: 'operator_refused_adopt_customer_mismatch',
      customer_taken: 'operator_refused_adopt_customer_taken',
      needs_confirmation: 'operator_refused_adopt_needs_confirmation',
      taken_concurrently: 'operator_refused_adopt_taken_concurrently'
    }.freeze

    INBOX_STATUSES = StripeEventInbox::STATUSES
    # What an operator opens this tab to see: the rows that are stuck, not the
    # thousands that worked.
    DEFAULT_INBOX_STATUSES = [StripeEventInbox::FAILED, StripeEventInbox::PROCESSING].freeze

    rescue_from Refused, with: :refused

    def show
      load_page
    end

    # Hand one inbox row back to Sidekiq, through the same two class methods
    # the nightly sweep uses — the claim logic has one home, not two.
    def retry_event
      reason = required_reason
      inbox = find_inbox!

      assert_retryable!(inbox)

      was = inbox.status

      ApplicationRecord.transaction do
        # A row stuck in `processing` is held by a claim no worker will ever
        # release, and the claim is a compare-and-set: it has to be handed
        # back to `failed` before anything can pick it up again. The release
        # is conditional on the row STILL being a stale claim, so a worker
        # that took it in the meantime keeps it — and then this refuses.
        self.class.release_claim!(inbox) if was == StripeEventInbox::PROCESSING

        raise Refused, t('operator_refused_event_in_flight') \
          if inbox.reload.status == StripeEventInbox::PROCESSING

        record!('stripe.retry_event', account: Account.find_by(id: inbox.account_id), subject: inbox, reason:,
                                      details: { stripe_event_id: inbox.stripe_event_id,
                                                 event_type: inbox.event_type, was: })
      end

      StripeReconciliationJob.requeue!([inbox.id])

      redirect_to operator_billing_path(inbox_filter), notice: t('operator_notice_event_requeued')
    end

    # Tie a live Stripe subscription nobody's row names to an account.
    #
    # Adoption is a decision for a person — the sweep only ever NAMES these,
    # because writing a subscription onto a row on the strength of a list is
    # how paid access gets granted for somebody else's purchase.
    #
    # This door asks for the account, a reason, and — when the subscription
    # carries neither our own account tag nor a customer we can place — an
    # explicit acknowledgement that the operator means this account. Every
    # ownership question is then asked again by StripeBilling::Linker.adopt!
    # INSIDE the row lock, against Stripe's own answer, and the audit row
    # below is written in that same transaction: a refusal leaves nothing
    # behind, and nothing is adopted without its OperatorEvent.
    #
    # The whole action is one transaction, so the empty subscription row this
    # creates for an account that has never bought anything is rolled back
    # with everything else when the adoption is refused.
    def adopt
      reason = required_reason
      subscription_id = params[:subscription_id].to_s.strip
      account = adoption_target!

      ApplicationRecord.transaction { adopt!(account, subscription_id, reason) }

      redirect_to operator_billing_path, notice: t('operator_notice_subscription_adopted', id: subscription_id)
    rescue StripeBilling::Linker::AdoptionRefused => e
      raise Refused, adoption_refusal(e)
    rescue Stripe::StripeError, StripeBilling::ListIncomplete, ActiveRecord::LockWaitTimeout => e
      raise Refused, t('operator_refused_stripe_unreachable', error: e.class.name)
    end

    # Releasing ONE row's stale claim, through the sweep's own writer so the
    # note and the state transition cannot drift — and through the model's own
    # `stale_claims` scope, so the staleness is re-decided BY THE WRITE rather
    # than by a read taken a moment earlier. A claim a live worker took in
    # between matches nothing and is left alone. Answers how many rows moved.
    def self.release_claim!(inbox)
      StripeReconciliationJob.release_stale_claims!(StripeEventInbox.stale_claims.where(id: inbox.id))
    end

    private

    def load_page
      load_revenue
      load_inbox
      @report = StripeReconciliationState.last_report
      @stripe_dashboard_url = OperatorConsole.stripe_dashboard_root
    end

    # --- the money ---------------------------------------------------------

    # Rows on real accounts only: a testing child is a corner of its parent
    # and never bills for itself, so a row on one is noise.
    def billing_rows
      AccountSubscription.where.not(account_id: Account.testing_child_ids)
    end

    # The rows in a paying access state that Stripe is actually collecting
    # from: the state says the seat is sold, `stripe_status` says the card has
    # been charged for it at least once.
    def collecting_rows
      billing_rows.where(access_state: PAYING_STATES)
                  .where('stripe_status IS DISTINCT FROM ?', TRIALING_STATUS)
    end

    def load_revenue
      paying = collecting_rows.where(comp_expires_at: nil)
                              .where('status IS DISTINCT FROM ?', COMP_STATUS)

      @paying_rows = paying.count
      @paying_seats = paying.sum(:quantity)
      # Business includes its first seat and packs are recurring revenue too.
      # Batch rows so the same invoice calculation serves both billing pages
      # without loading every account's subscription into memory at once.
      @mrr = paying.find_each.sum(&:monthly_amount_usd)
      # The census is left keyed on the access state, because `canceling` is
      # the honest answer to "what is this account's access?" — it is only the
      # MONEY that a cancelled trial must not be counted in. So the trial
      # sitting in a paying state is added back here rather than moved there.
      @by_state = billing_rows.group(:access_state).count
      @trials = @by_state.fetch('trialing', 0) + cancelling_trials

      load_month_numbers
      load_attention_rows
    end

    # A trial the customer has already called off: still a trial to Stripe,
    # already `canceling` to us.
    def cancelling_trials
      billing_rows.where(access_state: PAYING_STATES, stripe_status: TRIALING_STATUS).count
    end

    def load_month_numbers
      month_start = Time.current.utc.beginning_of_month

      @trials_started = billing_rows.where(trial_used_at: month_start..).count
      # A trial converts by simply ending: Stripe charges the card and the
      # subscription becomes `active`. So a row whose trial END is inside this
      # month and already past, and which is paying now, converted this month.
      # It is the honest reading of the columns we keep — there is no
      # "converted_at" — and the page states the definition rather than
      # printing a number nobody can check.
      #
      # `collecting_rows` rather than the access state alone, or a trial
      # cancelled from the Portal would be counted as a CONVERSION in the
      # window between its trial end passing and Stripe's cancellation
      # reaching us (session 10, seam M1).
      @conversions = collecting_rows.where(trial_end: month_start..Time.current).count
      @cancelled_this_month = billing_rows.where(access_state: 'cancelled').where(ended_at: month_start..).count
    end

    def load_attention_rows
      @comps = billing_rows.where(comp_expires_at: Time.current..).preload(:account).order(:comp_expires_at)
      @refunds_owed = billing_rows.where.not(refund_owed_subscription_id: nil).preload(:account).order(id: :desc)
    end

    # --- the inbox ---------------------------------------------------------

    def load_inbox
      @inbox_statuses = requested_inbox_statuses
      # StripeEventInbox names an account by id and keeps no association to
      # one — the row is stored before anybody knows which account the event
      # is about — so the page links by id rather than preloading.
      rows = StripeEventInbox.where(status: @inbox_statuses).order(id: :desc)

      @pagy, @events = pagy_auto(rows)
      @retryable_ids = retryable_ids(@events)
      @inbox_counts = StripeEventInbox.group(:status).count
    end

    def requested_inbox_statuses
      wanted = Array(params[:status]).map(&:to_s) & INBOX_STATUSES

      wanted.presence || DEFAULT_INBOX_STATUSES
    end

    # Which of the rows on this page the console will offer a Retry on,
    # decided by the model's own scopes so the button and the nightly sweep
    # agree about what "stuck" means.
    def retryable_ids(events)
      ids = events.map(&:id)

      (StripeEventInbox.where(id: ids).stuck.ids +
       StripeEventInbox.where(id: ids).retryable.ids +
       StripeEventInbox.where(id: ids).stale_claims.ids).to_set
    end

    def find_inbox!
      StripeEventInbox.find_by(id: params[:id]) || raise(Refused, t('operator_refused_event_missing'))
    end

    # The door asks the SAME questions the button does — the model's own
    # scopes — so a POST cannot do what the page would not offer (review 1,
    # M4 / C8). A `failed` row inside StripeEventInbox::RETRY_AFTER still
    # belongs to Sidekiq's retry chain, and enqueuing it again starts a second
    # worker racing the first for one compare-and-set claim; a row that has
    # spent its five attempts has no budget left to spend either way.
    def assert_retryable!(inbox)
      raise Refused, t('operator_refused_event_terminal', status: inbox.status) if inbox.terminal?

      scoped = StripeEventInbox.where(id: inbox.id)

      return if scoped.stuck.exists? || scoped.stale_claims.exists? || scoped.retryable.exists?

      raise Refused, t('operator_refused_event_exhausted', count: StripeEventInbox::MAX_ATTEMPTS) \
        if inbox.status == StripeEventInbox::FAILED && inbox.attempts >= StripeEventInbox::MAX_ATTEMPTS

      raise Refused, t('operator_refused_event_in_flight')
    end

    def inbox_filter
      { status: Array(params[:status]).map(&:to_s) & INBOX_STATUSES }.compact_blank
    end

    # --- adoption ----------------------------------------------------------

    def adoption_target!
      raise Refused, t('operator_refused_adopt_no_stripe') if StripeBilling.api_key.blank?

      account = console_accounts.find_by(id: params[:account_id].to_s.strip)

      raise Refused, t('operator_refused_adopt_no_account', id: params[:account_id].to_s.strip) if account.nil?

      assert_actionable!(account)

      raise Refused, t('operator_refused_already_purged') if account.purged?
      raise Refused, t('operator_refused_adopt_pending_deletion') if account.pending_deletion?

      account
    end

    # Inside the action's transaction: the row to adopt onto, and the locked
    # adoption itself with its audit row written in the same breath.
    def adopt!(account, subscription_id, reason)
      row = adoptable_row!(account, subscription_id)
      confirmed = params[:confirm_untagged].present?

      StripeBilling::Linker.adopt!(row, subscription_id, confirm_untagged: confirmed) do |subscription, replaced|
        OperatorEvents.record!(
          operator: true_user, action: 'stripe.adopt', account:, subject: row, reason:,
          details: { subscription: subscription_id, customer: row.stripe_customer_id,
                     access_state: row.access_state, confirmed_untagged: confirmed,
                     # What the row was holding, when the adoption replaced a
                     # subscription Stripe had already finished with.
                     replaced: replaced,
                     tagged_account_id: StripeBilling::SubscriptionPolicy
                                          .tagged_account_id(subscription).presence },
          request:
        )
      end
    end

    # The row the subscription lands on. Everything about the SUBSCRIPTION is
    # decided under the lock (StripeBilling::Linker.adopt!); the only thing
    # decided here is which row that is — and that this account bills for
    # itself, because a linked child's plan is read off its parent's row.
    def adoptable_row!(account, subscription_id)
      raise Refused, t('operator_refused_adopt_no_subscription') if subscription_id.blank?

      billing = Plans.billing_account(account)

      raise Refused, t('operator_refused_adopt_child', id: billing.id) if billing != account

      taken = AccountSubscription.where(stripe_subscription_id: subscription_id)
                                 .where.not(account_id: account.id).pick(:account_id)

      raise Refused, t('operator_refused_adopt_taken', id: taken) if taken

      # The Linker only ever writes onto a row that already exists (Checkout
      # creates it before it sells anything), so an account that has never
      # been through a purchase gets the same empty row here — free, holding
      # nothing — for the adoption to land on. The action's transaction takes
      # it away again if the adoption is refused.
      AccountSubscription.find_or_initialize_by(account:)
                         .tap { |row| row.update!(access_state: 'cancelled', status: 'none') if row.new_record? }
    end

    def adoption_refusal(error)
      key = ADOPTION_REFUSALS.fetch(error.reason, 'operator_refused_adopt_not_ours')

      t(key, **error.detail.symbolize_keys)
    end

    # --- refusals ----------------------------------------------------------

    def refused(error)
      refused_page(error, :show) { load_page }
    end
  end
end
