# frozen_string_literal: true

module Operator
  # Starting and ending a support session: an operator looking at a customer's
  # account as one of its people.
  #
  # Two things guard the start and they are not the same thing. The REASON is
  # for the customer — it is what the "Support access" card on their account
  # page shows them, and what the audit log shows us. The 6-digit code is the
  # freshness proof: operator access is a property of a login that may have
  # been open all day, and stepping inside somebody else's account is not
  # something a borrowed laptop should be able to do. Devise consumes the code,
  # so a code that has already been used is refused.
  #
  # The end door is deliberately a route of its own rather than a corner of the
  # account page: the banner on every impersonated page posts to it, so the
  # session can always be walked out of from wherever the operator is.
  class ImpersonationsController < BaseController
    rescue_from Refused, with: :refused

    def create
      @account = console_accounts.find_by(id: params[:account_id])

      raise Refused, t('operator_impersonation_refused_unknown_account') if @account.nil?

      assert_actionable!(@account)
      assert_no_session!

      user = eligible_user!
      reason = impersonation_reason
      mode = impersonation_mode

      assert_fresh_two_factor!

      start!(user, reason:, mode:)

      redirect_to root_path, notice: t('support_impersonation_started_notice', email: user.email)
    end

    def destroy
      state = support_impersonation

      raise Refused, t('operator_impersonation_refused_not_active') if state.blank?

      account = end_support_impersonation!(state, ended_by: 'operator')

      redirect_to(account ? operator_account_path(account) : operator_accounts_path,
                  notice: t('support_impersonation_ended_notice'), status: :see_other)
    end

    private

    # Test mode and a support session must never overlap: one impersonation at
    # a time, and the support one wins because it is the one with a reason and
    # an audit trail behind it.
    def start!(user, reason:, mode:)
      stop_impersonating_user if current_user != true_user

      event = OperatorEvents.record!(operator: true_user, action: 'impersonation.start', account: @account,
                                     subject: user, reason:,
                                     details: { mode:, user_email: user.email }, request:)

      impersonate_user(user)

      session[SupportImpersonation::SESSION_KEY] = {
        'event_id' => event.id, 'started_at' => Time.current.iso8601, 'mode' => mode,
        'reason' => reason, 'account_id' => @account.id, 'user_id' => user.id,
        # Who is inside. Carried on the session because the one door that has
        # to refuse without Devise reads the operator from here
        # (SupportImpersonationSessionRefusal).
        'operator_id' => true_user.id, 'refused_count' => 0
      }

      notify_customer(event)
    end

    # The customer is told, every time, by mail to the people who administer
    # the account — support access nobody outside support can see is the thing
    # this feature must never be. Internal accounts (our own) are the one
    # exception: the history row is still written, and there is nobody to tell.
    def notify_customer(event)
      return unless @account.customer?

      AccountMailer.support_access_started(@account, event).deliver_later!
    end

    # Who may be viewed as, and the plain sentence for everybody who may not.
    def eligible_user!
      user = @account.users.find_by(id: params[:user_id])

      raise Refused, t('operator_impersonation_refused_unknown_user') if user.nil?
      raise Refused, t('operator_impersonation_refused_archived') if user.archived_at?
      raise Refused, t('operator_impersonation_refused_integration') if user.role == 'integration'
      raise Refused, t('operator_impersonation_refused_operator_user') if user.platform_operator?

      user
    end

    def assert_actionable!(account)
      raise Refused, t('operator_impersonation_refused_purged') if account.purged?

      super
    end

    def assert_no_session!
      return if support_impersonation.blank?

      raise Refused, t('operator_impersonation_refused_already_active')
    end

    # The same validation the sign-in form and the 2FA setup page use, drift
    # and all, and the same consumption: a code already spent is refused.
    def assert_fresh_two_factor!
      code = params[:otp_attempt].to_s.strip

      raise Refused, t('operator_impersonation_refused_code') if code.blank?
      raise Refused, t('operator_impersonation_refused_code') unless true_user.validate_and_consume_otp!(code)
    end

    def impersonation_reason
      reason = params[:reason].to_s.strip

      raise Refused, t('operator_impersonation_refused_reason', count: SupportImpersonation::MINIMUM_REASON_LENGTH) \
        if reason.length < SupportImpersonation::MINIMUM_REASON_LENGTH

      reason
    end

    def impersonation_mode
      mode = params[:mode].to_s.presence || SupportImpersonation::READ_ONLY_MODE

      raise Refused, t('operator_impersonation_refused_mode') unless SupportImpersonation::MODES.include?(mode)

      mode
    end

    # Unlike the account console's own refusals there is no page here to render
    # the reason onto — the start door is a modal on somebody else's page and
    # the end door has no page at all — so the operator is sent back to the
    # account with the sentence in the flash. Nothing was changed either way.
    def refused(error)
      audit_refusal!(error)

      redirect_to(@account ? operator_account_path(@account) : operator_accounts_path, alert: error.message)
    end

    # A refused START is a refusal like any other and the customer's audit log
    # says so (review batch 2): somebody trying repeatedly to get into an
    # account — with the wrong code, at an archived person, or while another
    # session is running — used to leave no trace at all. The typed reason is
    # kept because it is the operator's own words; the authenticator code
    # never is.
    def audit_refusal!(error)
      OperatorEvents.record!(
        operator: true_user, action: 'impersonation.refused', account: @account,
        reason: params[:reason].to_s.strip.presence,
        details: { target: "#{controller_path}##{action_name}", refusal: error.message,
                   user_id: params[:user_id].presence, mode: params[:mode].presence },
        request:
      )
    end
  end
end
