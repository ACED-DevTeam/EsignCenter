# frozen_string_literal: true

# The request-level half of support impersonation (the "braces"; CanCan is the
# belt). One before_action on every controller in the application, including
# the ones that skip authentication, because the doors this has to close
# include the signer's own — an operator must never be able to complete a form
# as the person they are viewing as, and those are public slug URLs with no
# authorization of their own to hang a rule on.
#
# Three things happen here and nothing else:
#
#   * a session whose hour is up is ENDED, wherever the operator happens to
#     be, and they are put back on the account page;
#   * a request the session may not make is REFUSED with a 403 and an audit
#     row, and nothing downstream ever runs;
#   * a stale session key left behind by a sign-out is thrown away.
module SupportImpersonationGuard
  extend ActiveSupport::Concern

  included do
    helper_method :support_impersonation, :support_impersonation?, :support_impersonation_mode
  end

  private

  # Never memoized: the hash is written back to the session when a refusal is
  # counted and deleted when the session ends, and a stale copy would make the
  # banner lie.
  def support_impersonation
    value = session[SupportImpersonation::SESSION_KEY]

    value.is_a?(Hash) ? value : nil
  end

  def support_impersonation?
    support_impersonation.present?
  end

  def support_impersonation_mode
    support_impersonation&.[]('mode')
  end

  def enforce_support_impersonation!
    state = support_impersonation

    return if state.blank?

    # Signed out with the cookie still in hand: there is nobody to impersonate
    # and nothing to audit, so the key simply goes.
    if true_user.blank?
      session.delete(SupportImpersonation::SESSION_KEY)

      return
    end

    return expire_support_impersonation!(state) if SupportImpersonation.expired?(state)

    return unless SupportImpersonation.refuse?(controller_path:, action: action_name, mode: state['mode'],
                                               read_request: read_request?)

    refuse_support_impersonation!(state)
  end

  def read_request?
    %w[GET HEAD OPTIONS].include?(request.request_method)
  end

  # Ends the session and writes the row that says how long it lasted and how
  # many refusals it collected. Returns the account, so the caller knows where
  # to send the operator.
  def end_support_impersonation!(state, ended_by:)
    account = Account.find_by(id: state['account_id'])
    start = SupportImpersonation.started_at(state)

    OperatorEvents.record!(
      operator: true_user, action: 'impersonation.end', account:,
      subject: User.find_by(id: state['user_id']), reason: state['reason'],
      details: { start_event_id: state['event_id'], ended_by:, mode: state['mode'],
                 duration_seconds: start && (Time.current - start).round,
                 refused_count: state['refused_count'].to_i },
      request:
    )

    stop_impersonating_user
    session.delete(SupportImpersonation::SESSION_KEY)

    account
  end

  def expire_support_impersonation!(state)
    account = end_support_impersonation!(state, ended_by: 'timeout')
    message = I18n.t('support_impersonation_timed_out')

    if json_request?
      render json: { error: message }, status: :forbidden
    else
      redirect_to(account ? operator_account_path(account) : operator_accounts_path, notice: message)
    end
  end

  # A refusal is not a 500 and never a silent no-op: the operator gets a page
  # that says what is locked and why, the customer's audit log gets a row, and
  # the running count on the session is what the end row reports.
  def refuse_support_impersonation!(state)
    state['refused_count'] = state['refused_count'].to_i + 1
    session[SupportImpersonation::SESSION_KEY] = state

    OperatorEvents.record!(
      operator: true_user, action: 'impersonation.refused',
      account: Account.find_by(id: state['account_id']),
      subject: User.find_by(id: state['user_id']), reason: state['reason'],
      details: { path: request.path, method: request.request_method,
                 target: "#{controller_path}##{action_name}", mode: state['mode'] },
      request:
    )

    if json_request?
      render json: { error: I18n.t('support_impersonation_refused_json') }, status: :forbidden
    else
      render template: 'shared/support_impersonation_refused', layout: 'application', status: :forbidden
    end
  end

  def json_request?
    request.format.json? || request.xhr? || request.content_mime_type&.json? || false
  end
end
