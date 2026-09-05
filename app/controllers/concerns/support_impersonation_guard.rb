# frozen_string_literal: true

# The request-level half of support impersonation (the "braces"; CanCan is the
# belt). One before_action on every controller in the application — the ones
# that skip authentication and the JSON API included, because the doors this
# has to close include the signer's own (public slug URLs with no
# authorization to hang a rule on) and `/api/*` (which accepts the browser
# session).
#
# Five things happen here and nothing else:
#
#   * a session whose BINDING has changed — the operator lost platform access,
#     the person was archived, or they moved to another account — is ended on
#     the spot. "Cut this operator off now" has to work on the next request,
#     not at the end of the hour;
#   * a session whose hour is up is ended, wherever the operator has got to;
#   * a request the session may not make is refused with a 403 and an audit
#     row, and nothing downstream ever runs;
#   * a request that CHANGES something and was allowed leaves an audit row of
#     its own — written after the whole request, error handling included, and
#     saying whether it actually changed anything — so an edit-mode session is
#     readable by what it did and not only by what it was stopped from doing
#     (review 8). One row per request either way: a refused request has a
#     refusal row and no action row;
#   * a stale session key left behind by a sign-out is thrown away.
#
# Ending never swallows a sign-out: "log me out" is answered by logging out,
# with the support session closed on the way past.
module SupportImpersonationGuard
  # The ids an audit row may name. An `impersonation.action` row has to say
  # WHICH template was renamed; it must never become a copy of the customer's
  # document values — and `external_id`, `application_key` and friends are
  # customer free text wearing an id-shaped key (review 8, V2-4). So the VALUE
  # has to look like a record id too: digits, or a UUID.
  RECORD_ID_KEY = /\A(?:id|[a-z0-9_]+_id)\z/
  RECORD_ID_VALUE = /\A(?:\d{1,20}|\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/i

  extend ActiveSupport::Concern

  included do
    # ActionController::API has no view layer and no `helper_method`; the JSON
    # surface includes this concern for the rule, not for the banner.
    if respond_to?(:helper_method)
      helper_method :support_impersonation, :support_impersonation?, :support_impersonation_mode
    end

    # The audit row for an ALLOWED edit-mode write is NOT hung off an
    # `after_action`: see `process_action` below for why.
  end

  # WHERE THE AUDIT ROW IS WRITTEN, AND WHY IT IS HERE (review 8, W1/Y1).
  #
  # This wraps the entire request — the callback chain, the action, the
  # rendering AND the `rescue_from` handlers, which live further down the
  # `process_action` chain than this module does. An `after_action` could not:
  # an exception skips the after callbacks, so every 4xx a `rescue_from`
  # answered (a validator's 422, a quota's 422, an entitlement's 403, a rate
  # limit's 429) left the customer's audit log with NO row at all, while the
  # identical 422 rendered by the controller itself got one. Two outcomes for
  # one kind of failure is not an audit.
  #
  # So: one writer, `ensure`-shaped, and exactly one row per request no matter
  # how the request ends —
  #
  #   * it returned normally (a render, a redirect, a Turbo stream);
  #   * a `rescue_from` answered it with a 4xx;
  #   * an exception escaped everything (outcome `error`, then re-raised
  #     untouched — the row is written on the way past, never instead of the
  #     error).
  #
  # The row is written OUTSIDE the action's transaction by construction: by the
  # time this runs, the action has returned and whatever transaction it opened
  # has already committed or rolled back. That is deliberate — an audit row
  # that rolls back with the change it was recording is not an audit row.
  def process_action(...)
    result = super

    record_support_impersonation_action!

    result
  rescue StandardError => e
    record_support_impersonation_action!(exception: e)

    raise
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

    if SupportImpersonation.refuse?(controller_path:, action: action_name, mode: state['mode'],
                                    read_request: read_request?, params: support_impersonation_payload(state))
      return refuse_support_impersonation!(state)
    end

    flag_support_impersonation_action!(state)
  end

  # The request body, handed to the rule only when the rule can actually need
  # it: an edit-mode write, on a door whose answer depends on the payload
  # (`permanently`, `completed`). Every other request is answered from the
  # table alone and does not pay for a copy of its own params.
  def support_impersonation_payload(state)
    return {} if read_request? || state['mode'] != SupportImpersonation::EDIT_MODE

    support_impersonation_params
  end

  # The request body, or an empty hash when there isn't one that can be read.
  #
  # A body Rails cannot parse used to take the whole rule down with it: the
  # parse error was raised out of the before_action, a `rescue_from` rendered
  # the 422, and the customer's log got NOTHING — no refusal, no action row
  # (review 8, W1). A malformed body cannot open any door either, because the
  # action reading it hits the same error, so reading it as "no payload" is
  # both honest and safe: the request is classified from the table, and if it
  # is allowed it gets its `failed` row when the parse error surfaces.
  def support_impersonation_params
    params.to_unsafe_h
  rescue StandardError
    {}
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

  # Ends the session and writes the row that says how long it lasted, how many
  # refusals it collected, and how many changes it made. Returns the account,
  # so the caller knows where to send the operator.
  def end_support_impersonation!(state, ended_by:)
    account = Account.find_by(id: state['account_id'])
    start = SupportImpersonation.started_at(state)

    OperatorEvents.record!(
      operator: true_user, action: 'impersonation.end', account:,
      subject: User.find_by(id: state['user_id']), reason: state['reason'],
      details: { start_event_id: state['event_id'], ended_by:, mode: state['mode'],
                 duration_seconds: start && (Time.current - start).round,
                 refused_count: state['refused_count'].to_i,
                 action_count: state['action_count'].to_i },
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

  # Half of the audit is decided BEFORE the action runs: whether this request
  # is one that deserves an `impersonation.action` row at all. The rule has
  # just said yes, so what is left is the shape of the request.
  #
  # Two writes are deliberately left out because they already have a row of
  # their own: the operator's console (its mutations audit themselves, and the
  # end door lives there) and signing out (which writes `impersonation.end`).
  def flag_support_impersonation_action!(state)
    return if read_request? || state['mode'] != SupportImpersonation::EDIT_MODE
    return if SupportImpersonation.console?(controller_path) || sign_out_request?

    # The alert this request STARTED with, so the outcome can tell an alert
    # this action set from one left over from the last request (review 8, Y3).
    # Flash survives into the next request by design; a leftover must not be
    # read as this action's own refusal.
    @support_impersonation_incoming_alert = support_impersonation_alert
    @support_impersonation_action = true
  end

  # The other half of the audit (review 8, blocker 1): an edit-mode session is
  # judged by what it DID, not only by what it was refused. Every write the
  # rule let through leaves exactly one row — the controller action, the record
  # ids the request named, whether it changed anything, and the account and
  # person it was made as — so "support archived six submissions and changed a
  # signer's email address" is readable off the customer's own log a month
  # later.
  #
  # EXACTLY ONE ROW PER REQUEST, and it is honest about the outcome (review 8,
  # X4/W1/Y1/Y3):
  #
  #   * refused by the request rule — the before_action chain halted and the
  #     flag below was never set. One `impersonation.refused` row, no action
  #     row;
  #   * refused by the ability layer — CanCan raises, `rescue_from` answers,
  #     and the refusal writer sets `@support_impersonation_refused`. A request
  #     that has already written a refusal row never writes an action row too;
  #   * allowed and it went through — `changed`, and it is the only outcome
  #     that counts towards the "Actions" total the customer is shown;
  #   * allowed and it did not go through — `failed`. A 4xx, whoever rendered
  #     it, or a redirect carrying an alert, which is how half this
  #     application says no (a signer update on a submission that has already
  #     started, a quota refusal on the HTML door). The row still lands,
  #     because support reaching for a door is worth recording, but nothing
  #     changed and the customer is not told it did;
  #   * allowed and it blew up — `error`, written on the way past while the
  #     exception carries on to whoever owns the 500.
  #
  # Nothing in here may take a request down: an audit row that cannot be
  # written is reported, not raised, and least of all raised INSTEAD of the
  # exception that was already on its way out.
  def record_support_impersonation_action!(exception: nil)
    return unless @support_impersonation_action
    return if @support_impersonation_refused || @support_impersonation_action_recorded

    state = support_impersonation

    return if state.blank?

    @support_impersonation_action_recorded = true

    write_support_impersonation_action!(state, support_impersonation_outcome(exception))
  rescue StandardError => e
    ErrorReport.error(e)

    nil
  end

  # The ROW FIRST and the counter second, deliberately: the number the customer
  # is shown is a count of rows in their own audit log, so a write that fails
  # must not leave the total claiming a change nobody can look up.
  def write_support_impersonation_action!(state, outcome)
    record_support_impersonation_request!('impersonation.action', state,
                                          outcome:, records: support_impersonation_record_ids)

    return unless outcome == SupportImpersonation::ACTION_CHANGED

    state['action_count'] = state['action_count'].to_i + 1
    session[SupportImpersonation::SESSION_KEY] = state
  end

  # What actually happened, read off the finished request. The status is the
  # first word and the flash is the second: a controller that answers a
  # request it will not carry out with `redirect_back alert:` has said no just
  # as plainly as a 422, and counting that as a change told the customer
  # support had edited something it had not (review 8, Y3).
  def support_impersonation_outcome(exception)
    return SupportImpersonation::ACTION_ERROR if exception
    return SupportImpersonation::ACTION_FAILED if response.status >= 400
    return SupportImpersonation::ACTION_FAILED if response.status >= 300 && support_impersonation_refusal_alert?

    SupportImpersonation::ACTION_CHANGED
  end

  # An alert THIS action set, not one the previous request left in the flash
  # for a page that has not drawn it yet.
  def support_impersonation_refusal_alert?
    alert = support_impersonation_alert

    alert.present? && !alert.equal?(@support_impersonation_incoming_alert)
  end

  # The JSON surface has no flash at all (ActionController::API), and a
  # session that cannot be read is not a reason to lose the row.
  def support_impersonation_alert
    return nil unless respond_to?(:flash, true)

    flash[:alert]
  rescue StandardError
    nil
  end

  # The ids the request names, and nothing else: an id-shaped KEY carrying an
  # id-shaped VALUE. Anything else is dropped rather than copied into a log
  # that outlives the record.
  def support_impersonation_record_ids
    support_impersonation_params.filter_map do |key, value|
      next unless key.to_s.match?(RECORD_ID_KEY)
      next unless value.is_a?(String) || value.is_a?(Integer)
      next unless value.to_s.match?(RECORD_ID_VALUE)

      [key.to_s, value.to_s]
    end.to_h
  end

  # One writer for every refusal a support session meets, so the door that
  # said no does not decide whether the customer hears about it. Called by the
  # rule above AND by the CanCan handlers, which used to refuse silently.
  def record_support_impersonation_refusal!(state = support_impersonation, extra = {})
    return if state.blank?

    # One row per request: whatever else happens to this request, it has now
    # had its say in the customer's log, and the action writer stands down.
    @support_impersonation_refused = true

    record_support_impersonation_request!('impersonation.refused', state, extra)
  end

  # The two rows a support session writes DURING a request — the refusal and
  # the action — are the same row with a different verb: the same operator,
  # the same account, the same person and the same reason, all read off the
  # session state (the session IS the binding), and the same four facts about
  # the request. Written in one place so an `action` row and a `refused` row
  # can never come to describe the request differently, and so a row can never
  # quietly stop naming one of them. WHEN each is written, and whether, is
  # decided by the callers above and is unchanged by living here.
  def record_support_impersonation_request!(action, state, extra = {})
    OperatorEvents.record!(
      operator: true_user, action:,
      account: Account.find_by(id: state['account_id']),
      subject: User.find_by(id: state['user_id']), reason: state['reason'],
      details: { path: SupportImpersonation.audit_path(request), method: request.request_method,
                 target: "#{controller_path}##{action_name}", mode: state['mode'] }.merge(extra),
      request:
    )
  end

  def json_request?
    request.format.json? || request.xhr? || request.content_mime_type&.json? || false
  end
end
