# frozen_string_literal: true

# Gate for platform-operator surfaces. Anyone who is not an operator with 2FA
# gets a 404 — the same answer as a route that does not exist — so the surface
# is never revealed by a redirect or a 403.
module OperatorAccess
  extend ActiveSupport::Concern

  included do
    helper_method :operator_access?
  end

  private

  # Operator access is a property of the authenticated human (the Warden
  # user, `true_user`), exactly as the /jobs route constraint sees it. Test
  # mode impersonates a testing user but never changes who is signed in, so
  # it neither grants nor removes operator access.
  def operator_access?
    true_user&.operator_access? == true
  end

  def require_operator_access!
    return if operator_access?

    raise ActionController::RoutingError, I18n.t('not_found') if request.format.html?

    head :not_found
  end
end
