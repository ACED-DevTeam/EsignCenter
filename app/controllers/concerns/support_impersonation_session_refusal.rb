# frozen_string_literal: true

# The support rule for a controller that honours the session COOKIE but has
# none of the machinery the full guard needs — no Devise, no Pretender, no
# CanCan. Today that is exactly one door, `Api::AttachmentsController`, and it
# is the one review batch 2 caught: it is keyed on a submitter slug the
# operator can read off the customer's own submission page, so a READ-ONLY
# session could attach a signature image to a live submitter in the customer's
# evidence chain — no 403, no audit row, nothing on the Support-access card.
#
# The decision comes from the same classification as everywhere else
# (SupportImpersonation.refuse?), so the table stays the single source of
# truth rather than this file being a second opinion. The operator is read off
# the session state, because there is no `true_user` here to ask.
module SupportImpersonationSessionRefusal
  extend ActiveSupport::Concern

  included do
    before_action :refuse_support_impersonation_session!
  end

  private

  def refuse_support_impersonation_session!
    state = request.session[SupportImpersonation::SESSION_KEY]

    return unless state.is_a?(Hash)
    return unless SupportImpersonation.refuse?(controller_path:, action: action_name, mode: state['mode'],
                                               read_request: request.get? || request.head?)

    state['refused_count'] = state['refused_count'].to_i + 1
    request.session[SupportImpersonation::SESSION_KEY] = state

    OperatorEvents.record!(
      operator: User.find_by(id: state['operator_id']), action: 'impersonation.refused',
      account: Account.find_by(id: state['account_id']),
      subject: User.find_by(id: state['user_id']), reason: state['reason'],
      details: { path: request.path, method: request.request_method,
                 target: "#{controller_path}##{action_name}", mode: state['mode'] },
      request:
    )

    render json: { error: I18n.t('support_impersonation_refused_json') }, status: :forbidden
  end
end
