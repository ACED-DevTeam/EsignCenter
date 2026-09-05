# frozen_string_literal: true

# The request-level half of support impersonation (the "braces"; CanCan is the
# belt). One before_action on every controller in the application — the ones
# that skip authentication and the JSON API included, because the doors this
# has to close include the signer's own (public slug URLs with no
# authorization to hang a rule on) and `/api/*` (which accepts the browser
# session).
#
# Four things happen here and nothing else:
#
#   * a session whose BINDING has changed — the operator lost platform access,
#     the person was archived, or they moved to another account — is ended on
#     the spot. "Cut this operator off now" has to work on the next request,
#     not at the end of the hour;
#   * a session whose hour is up is ended, wherever the operator has got to;
#   * a request the session may not make is refused with a 403 and an audit
#     row, and nothing downstream ever runs;
#   * a stale session key left behind by a sign-out is thrown away.
#
# Ending never swallows a sign-out: "log me out" is answered by logging out,
# with the support session closed on the way past.
module SupportImpersonationGuard
  extend ActiveSupport::Concern

  included do
    # ActionController::API has no view layer and no `helper_method`; the JSON
    # surface includes this concern for the rule, not for the banner.
    if respond_to?(:helper_method)
      helper_method :support_impersonation, :support_impersonation?, :support_impersonation_mode
    end
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

    ended_by = support_impersonation_over(state)

    return finish_support_impersonation!(state, ended_by:) if ended_by

    return unless SupportImpersonation.refuse?(controller_path:, action: action_name, mode: state['mode'],
                                               read_request: read_request?)

    refuse_support_impersonation!(state)
  end

  # Why this session is over, or nil while it is still the session that was
  # started. Every one of these is re-asked on EVERY request: a support
  # session is a live binding between one operator, one person and one
  # account, and any of the three can change underneath it.
  def support_impersonation_over(state)
    # Platform access revoked (the flag pulled, or their 2FA removed).
    return 'operator_access_lost' unless true_user.operator_access?

    target = User.find_by(id: state['user_id'])

    # The person is gone, archived, or has moved to another account — a team
    # invitation accepted in another browser must never carry a support
    # session into the new tenant.
    return 'rebinding' if target.nil? || target.archived_at? ||
                          target.account_id != state['account_id'] ||
                          target.uuid != session[:impersonated_user_id]

    'timeout' if SupportImpersonation.expired?(state)
  end

  def read_request?
    %w[GET HEAD OPTIONS].include?(request.request_method)
  end

  def sign_out_request?
    controller_path == 'sessions' && action_name == 'destroy'
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

  # End it, then say so — unless the request in hand IS the sign-out, in which
  # case the chain carries on into Devise and the operator really is signed
  # out. Answering "log me out" with a redirect to the console, still
  # authenticated, was the bug (review batch 2).
  def finish_support_impersonation!(state, ended_by:)
    account = end_support_impersonation!(state, ended_by:)

    return if sign_out_request?

    message = I18n.t("support_impersonation_ended_#{ended_by}")

    if json_request?
      render json: { error: message }, status: :forbidden
    else
      redirect_to(support_impersonation_exit_path(ended_by, account), notice: message)
    end
  end

  # Where the operator is put down. The console, normally — except when the
  # reason the session ended is that they can no longer OPEN the console, in
  # which case every page under /operator answers 404 and the redirect would
  # land them on one (review batch 2, N3).
  def support_impersonation_exit_path(ended_by, account)
    return root_path if ended_by == 'operator_access_lost'

    account ? operator_account_path(account) : operator_accounts_path
  end

  # A refusal is not a 500 and never a silent no-op: the operator gets a page
  # that says what is locked and why, the customer's audit log gets a row, and
  # the running count on the session is what the end row reports.
  def refuse_support_impersonation!(state)
    state['refused_count'] = state['refused_count'].to_i + 1
    session[SupportImpersonation::SESSION_KEY] = state

    record_support_impersonation_refusal!(state)

    if json_request?
      render json: { error: I18n.t('support_impersonation_refused_json') }, status: :forbidden
    else
      render template: 'shared/support_impersonation_refused', layout: 'application', status: :forbidden
    end
  end

  # One writer for every refusal a support session meets, so the door that
  # said no does not decide whether the customer hears about it. Called by the
  # rule above AND by the CanCan handlers, which used to refuse silently.
  def record_support_impersonation_refusal!(state = support_impersonation, extra = {})
    return if state.blank?

    OperatorEvents.record!(
      operator: true_user, action: 'impersonation.refused',
      account: Account.find_by(id: state['account_id']),
      subject: User.find_by(id: state['user_id']), reason: state['reason'],
      details: { path: request.path, method: request.request_method,
                 target: "#{controller_path}##{action_name}", mode: state['mode'] }.merge(extra),
      request:
    )
  end

  def json_request?
    request.format.json? || request.xhr? || request.content_mime_type&.json? || false
  end
end
