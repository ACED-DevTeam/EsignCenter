# frozen_string_literal: true

module Operator
  # The console's heart: every account on the platform, what state it is in,
  # and the handful of things an operator may do to one.
  #
  # Two rules run through the whole file. Every query names the account the
  # operator picked — `current_account` is never consulted for data, because
  # the operator's own account is not the subject of any of these pages. And
  # every change is made INSIDE a transaction that also writes its
  # OperatorEvent, so an account cannot move without the audit line that says
  # who moved it and why; a refusal rolls both back and renders the same page
  # with the reason on it (422), never a 500 and never a silent no-op.
  class AccountsController < BaseController
    PLAN_FILTERS = (Plans::ACCESS_STATES + %w[free comp]).freeze
    STATE_FILTERS = %w[suspended sending_paused pending_deletion purged archived
                       read_only_members storage_over_cap].freeze
    SORTS = %w[created last_active name id].freeze

    # A purge claim younger than this is a purge that is RUNNING. Only an
    # older one is stuck enough to release by hand (the release un-freezes an
    # account whose rows may be half-deleted, so it is never the first move).
    STALE_CLAIM_AFTER = 1.hour

    before_action :load_account, except: :index

    rescue_from Refused, with: :refused
    rescue_from Plans::Manual::Refused, with: :refused
    rescue_from Accounts::Purge::Refused, with: :refused

    def index
      accounts = filtered_accounts

      @pagy, @accounts = pagy_auto(accounts)
      @usage = OperatorConsole.usage_for(@accounts)
      # One grouped query for the whole page rather than one per row: how many
      # people in each account lost their seat in a downgrade (D43).
      @read_only_counts = User.active.where.not(read_only_at: nil)
                              .where(account_id: @accounts.map(&:id)).group(:account_id).count
    end

    def show
      load_account_detail
    end

    # Read-only proof that a purge left nothing behind in the four tables with
    # no foreign key to `accounts` — the same four `rake accounts:purge`
    # prints. Writes nothing, so it records no event.
    def orphans
      @orphans = Accounts::Purge.orphans(@account.id)

      load_account_detail

      render :show
    end

    def suspend
      reason = required_reason

      assert_actionable!(@account)

      raise Refused, t('operator_refused_already_suspended') if @account.suspended_at.present?

      ApplicationRecord.transaction do
        raise Refused, t('operator_refused_suspend_failed') unless AccountStates.suspend!(@account, reason: 'operator')

        record!('account.suspend', reason:)
      end

      redirect_to operator_account_path(@account), notice: t('operator_notice_suspended')
    end

    # Only the operator's OWN suspension. A billing suspension lifts when the
    # payment goes through and a deletion suspension lifts when the deletion
    # is called off; lifting either from here would hand a fully writable
    # account back to somebody who is not paying, or who has asked us to
    # delete them.
    def lift_suspension
      reason = required_reason

      assert_actionable!(@account)
      assert_operator_suspension!

      ApplicationRecord.transaction do
        raise Refused, t('operator_refused_lift_failed') \
          unless AccountStates.lift_suspension!(@account, reason: 'operator')

        record!('account.lift_suspension', reason:)
      end

      redirect_to operator_account_path(@account), notice: t('operator_notice_suspension_lifted')
    end

    # Lifts the automatic abuse pause after a human has looked at it. The
    # AbuseFlags behind it are resolved by SendingPause.resume! itself; the
    # queue (next phase) is where a flag is judged, not here.
    def resume_sending
      reason = required_reason

      resume_sending!(@account, reason:)

      redirect_to operator_account_path(@account), notice: t('operator_notice_sending_resumed')
    end

    # The operator's half of "the customer changed their mind": the same door
    # `rake accounts:cancel_deletion` opens, with the same three refusals.
    def cancel_deletion
      reason = required_reason

      assert_actionable!(@account)

      raise Refused, t('operator_refused_already_purged') if @account.purged?
      raise Refused, t('operator_refused_not_pending_deletion') unless @account.pending_deletion?

      scheduled_for = @account.purge_scheduled_for

      cancel_deletion!(reason, scheduled_for)

      redirect_to operator_account_path(@account), notice: t('operator_notice_deletion_cancelled')
    end

    # Destroying an account NOW. Deliberately weaker than the rake task: the
    # console has no FORCE. An account that is not due to be purged is refused
    # here whatever anybody types, because the one mistake in this area that
    # cannot be undone should not be one button and a confirmation away.
    def purge
      reason = required_reason

      assert_purge_allowed!

      ApplicationRecord.transaction do
        record!('purge.run', reason:, details: { purge_scheduled_for: @account.purge_scheduled_for&.iso8601 })

        AccountPurgeJob.perform_later(@account.id)
      end

      redirect_to operator_account_path(@account), notice: t('operator_notice_purge_started')
    end

    # A purge that died part-way leaves the account claimed — archived, signed
    # out, refusing tokens — and nothing releases it by itself. This is the
    # release, and it is offered only once the claim is old enough to be stuck
    # rather than running.
    def release_purge_claim
      reason = required_reason

      raise Refused, t('operator_refused_already_purged') if @account.purged?
      raise Refused, t('operator_refused_no_purge_claim') if @account.purge_started_at.blank?
      raise Refused, t('operator_refused_claim_not_stale') if @account.purge_started_at > STALE_CLAIM_AFTER.ago

      claimed_at = @account.purge_started_at

      ApplicationRecord.transaction do
        Accounts::Purge.release_claim!(@account)

        record!('purge.release_claim', reason:, details: { claimed_at: claimed_at.iso8601 })
      end

      redirect_to operator_account_path(@account), notice: t('operator_notice_claim_released')
    end

    # Per-account limit overrides. A blank field means "use the plan default",
    # which is the same thing as clearing the column.
    def limits
      reason = required_reason

      assert_actionable!(@account)

      # On the BILLING account, never the one being viewed. Quotas.limits_for
      # resolves the billing account before it reads an override, so a row
      # saved on a linked child is read by nothing at all — the page would
      # paint the "Override" badge over a cap that had not moved (review 1,
      # M1). The comp card on the same page has always acted on the billing
      # account; the limits form now agrees with it, and says which account
      # the numbers belong to when the two differ.
      override = AccountLimitOverride.find_or_initialize_by(account: @billing)
      before = override.slice(*AccountLimitOverride::FIELDS)
      after = submitted_limits

      ApplicationRecord.transaction do
        save_override!(override, after)

        record!('limits.update', reason:, subject: override,
                                 details: { before:, after:, billing_account_id: @billing.id })
      end

      redirect_to operator_account_path(@account), notice: t('operator_notice_limits_saved')
    end

    # A comp: paid access given away, always with the date it ends.
    def comp_grant
      reason = required_reason

      assert_actionable!(@account)

      expires_at = comp_expiry!
      seats = [params[:seats].to_i, 1].max

      subscription = nil

      ApplicationRecord.transaction do
        subscription = Plans::Manual.grant!(@account, seats:, comp_expires_at: expires_at)

        record!('comp.grant', reason:, subject: subscription,
                              details: { seats:, comp_expires_at: expires_at.iso8601,
                                         billing_account_id: subscription.account_id })
      end

      redirect_to operator_account_path(@account), notice: t('operator_notice_comp_granted')
    end

    def comp_revoke
      reason = required_reason

      assert_actionable!(@account)

      ApplicationRecord.transaction do
        subscription = Plans::Manual.revoke!(@account)

        raise Refused, t('operator_refused_no_subscription') if subscription.nil?

        record!('comp.revoke', reason:, subject: subscription,
                               details: { billing_account_id: subscription.account_id })
      end

      redirect_to operator_account_path(@account), notice: t('operator_notice_comp_revoked')
    end

    private

    def load_account
      @account = find_account!
      # The account that PAYS for it, resolved once for every action: the comp
      # buttons and the limits form both write there, and the page says so
      # when the two differ.
      @billing = Plans.billing_account(@account)
    end

    # --- the index --------------------------------------------------------------

    def filtered_accounts
      # The parent's subscription and override too: a linked child's plan and
      # limits are read off the account that PAYS for it, so leaving them out
      # would put a query behind every such row.
      scope = console_accounts.preload(:account_subscription, :limit_override,
                                       linked_account_account: { account: %i[account_subscription limit_override] })
      scope = search(scope)
      scope = by_kind(scope)
      scope = by_plan(scope)
      scope = by_state(scope)

      sorted(scope)
    end

    # Id, name, or the address of anybody who signs in to it.
    def search(scope)
      query = params[:q].to_s.strip

      return scope if query.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      by_email = User.where(User.arel_table[:email].matches(pattern)).select(:account_id)
      matches = scope.where(Account.arel_table[:name].matches(pattern)).or(scope.where(id: by_email))

      query.match?(/\A\d+\z/) ? matches.or(scope.where(id: query.to_i)) : matches
    end

    def by_kind(scope)
      kind = params[:kind].to_s

      Account::KINDS.include?(kind) ? scope.where(account_kind: kind) : scope
    end

    # Reads the account's OWN subscription row. A linked child is paid for by
    # its parent, so its plan comes from the parent's row — the list says so
    # in the plan column, and this filter is about the row itself.
    def by_plan(scope)
      plan = params[:plan].to_s

      return scope unless PLAN_FILTERS.include?(plan)

      subscriptions = AccountSubscription.select(:account_id)

      case plan
      when 'comp' then scope.where(id: subscriptions.where.not(comp_expires_at: nil))
      when 'free' then scope.where.not(id: subscriptions.where(access_state: Plans::PAID_ACCESS_STATES))
      else scope.where(id: subscriptions.where(access_state: plan))
      end
    end

    def by_state(scope)
      state = params[:state].to_s

      return scope unless STATE_FILTERS.include?(state)

      case state
      when 'suspended' then scope.where.not(suspended_at: nil)
      when 'sending_paused' then scope.where.not(sending_paused_at: nil)
      when 'pending_deletion' then scope.pending_deletion
      when 'purged' then scope.where.not(purged_at: nil)
      when 'archived' then scope.where.not(archived_at: nil)
      when 'read_only_members' then scope.where(id: User.active.where.not(read_only_at: nil).select(:account_id))
      else over_storage_cap(scope)
      end
    end

    # The one filter the accounts table cannot answer: it needs every blob
    # every account owns. Weighed over a bounded slice, and the page says when
    # it had to stop (OperatorConsole::STORAGE_SCAN_LIMIT).
    def over_storage_cap(scope)
      ids, @storage_scan_truncated = OperatorConsole.over_storage_cap(scope)

      scope.where(id: ids)
    end

    def sorted(scope)
      case params[:sort].to_s
      when 'last_active' then scope.order(Arel.sql('last_active_at DESC NULLS LAST'), id: :desc)
      when 'name' then scope.order(:name, id: :desc)
      when 'id' then scope.order(id: :asc)
      else scope.order(created_at: :desc, id: :desc)
      end
    end

    # --- one account ------------------------------------------------------------

    def load_account_detail
      @plan = Plans.key_for(@account)
      @subscription = @billing.account_subscription
      @limits = Quotas.limits_for(@billing)
      @override = @billing.limit_override
      @usage = OperatorConsole.usage_for([@account]).fetch(@account.id)
      @pause_at, @pause_reason = SendingPause.state(@account)
      load_billing_doors

      load_account_people
      load_account_history
    end

    # Would the customer's own billing doors open right now? The same three
    # questions BillingSettingsController asks before it will price or open
    # anything, answered here so an operator on the phone can say which of them
    # is shut without guessing.
    def load_billing_doors
      own_billing = Docuseal.billing_enabled? && @account.customer? && @billing == @account &&
                    !@account.pending_deletion?

      @checkout_available = own_billing
      @portal_available = own_billing && @subscription&.stripe_customer_id.present?
    end

    def load_account_people
      @users = @account.users.order(Arel.sql('archived_at IS NULL DESC'), id: :asc)
      @read_only_count = @account.users.active.where.not(read_only_at: nil).count
      @invites = @account.account_invites.preload(:invited_by).order(id: :desc)
      @testing_children = @account.testing_accounts.to_a
    end

    def load_account_history
      @flags = @account.abuse_flags.open.order(created_at: :desc)
      @provisioning_events = @account.provisioning_events.preload(:account).order(id: :desc)
      @moves_in = AccountMove.where(to_account_id: @account.id).preload(:user, :from_account).order(id: :desc)
      @moves_out = AccountMove.where(from_account_id: @account.id).preload(:user, :to_account).order(id: :desc)
      @events = OperatorEvent.where(account_id: @account.id).newest_first.preload(:operator).limit(20)
    end

    # --- refusals ---------------------------------------------------------------

    # The SAME page, with the reason on it. 422 because nothing was changed:
    # the transaction the refusal was raised inside has already rolled back.
    def refused(error)
      @account ||= find_account!

      refused_page(error, :show) { load_account_detail }
    end

    def assert_operator_suspension!
      raise Refused, t('operator_refused_not_suspended') if @account.suspended_at.blank?

      return if @account.suspension_reason.to_s == 'operator'

      raise Refused, t("operator_refused_suspension_#{@account.suspension_reason}",
                       default: t('operator_refused_suspension_other'))
    end

    # Everything `rake accounts:purge` asks, minus its FORCE escape hatch, in
    # the order that makes the message useful.
    def assert_purge_allowed!
      raise Refused, t('operator_refused_already_purged') if @account.purged?
      raise Refused, t('operator_refused_purge_claimed') if @account.purge_started_at.present?

      # The platform and the live-subscription refusals, from the purge itself
      # rather than from a copy of them.
      Accounts::Purge.assert_purgeable!(@account)

      raise Refused, t('operator_refused_purge_not_due') unless Accounts::Retention.purge_eligible?(@account)
      raise Refused, t('operator_refused_purge_name') if params[:confirm_name].to_s.strip != @account.name
    end

    # Wrapped so a refusal AFTER the cancel — a purge that claimed the account
    # in between — rolls the cancel back with it rather than leaving the
    # deletion called off and no audit line saying so.
    def cancel_deletion!(reason, scheduled_for)
      ApplicationRecord.transaction do
        cancelled =
          begin
            Accounts::Deletion.cancel!(@account)
          rescue Accounts::Deletion::BillingUnsettled
            raise Refused, t('operator_refused_billing_unsettled')
          end

        raise Refused, t('operator_refused_purge_claimed') unless cancelled

        record!('deletion.cancel', reason:, details: { purge_scheduled_for: scheduled_for&.iso8601 })
      end
    end

    # --- writes -----------------------------------------------------------------

    # Blank clears the column (back to the plan default); storage is typed in
    # GB because nobody types 10737418240.
    #
    # A FIELD THAT IS NOT A NUMBER IS REFUSED, not read as zero (review 1,
    # B-L4). `"ten".to_i` is 0, and 0 is a real cap here — it means "this
    # account may not complete a single document this month" — so a typo used
    # to save cleanly as the harshest possible limit, with an audit row saying
    # the operator had chosen it. The form comes back with the sentence
    # instead and nothing is written.
    def submitted_limits
      values = params.fetch(:limits, {})

      AccountLimitOverride::FIELDS.index_with do |field|
        raw = (field == 'storage_bytes' ? values[:storage_gb] : values[field]).to_s.strip

        next nil if raw.blank?

        if field == 'api_completions_per_month' && raw == '-1'
          -1
        elsif field == 'storage_bytes'
          (decimal!(raw, 'storage (GB)') * 1.gigabyte).round
        else
          whole_number!(raw, field.humanize.downcase)
        end
      end
    end

    # Whole numbers only, and never negative: every field here is a count.
    def whole_number!(raw, field)
      raise Refused, t('operator_refused_limit_not_a_number', field:, value: raw) unless /\A\d+\z/.match?(raw)

      raw.to_i
    end

    # Storage is the one field typed in decimals (1.5 GB).
    def decimal!(raw, field)
      raise Refused, t('operator_refused_limit_not_a_number', field:, value: raw) unless /\A\d+(?:\.\d+)?\z/.match?(raw)

      raw.to_f
    end

    def save_override!(override, attributes)
      override.assign_attributes(attributes)

      raise Refused, override.errors.full_messages.to_sentence unless override.save

      override
    end

    # A comp always expires: a grant with no date is the reason a "two-week
    # pilot" is still running eight months later.
    def comp_expiry!
      raw = params[:comp_expires_on].to_s.strip

      raise Refused, t('operator_refused_comp_expiry_required') if raw.blank?

      expires_at = Time.find_zone('UTC').parse(raw)&.end_of_day

      raise Refused, t('operator_refused_comp_expiry_invalid') if expires_at.nil?
      raise Refused, t('operator_refused_comp_expiry_past') if expires_at <= Time.current

      expires_at
    end
  end
end
