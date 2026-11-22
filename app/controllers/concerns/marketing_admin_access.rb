# frozen_string_literal: true

# The gate for the private marketing page at /admin (lib/marketing_admin.rb).
# Anyone who is not on the list gets a 404 — the same answer as a route that
# does not exist — so the page is never revealed by a redirect to sign-in or
# by a 403.
module MarketingAdminAccess
  extend ActiveSupport::Concern

  included do
    helper_method :marketing_admin_access?
  end

  private

  # A property of the authenticated human (`true_user`), exactly as operator
  # access is: a support session inside the listed person's account does not
  # open the page, and test mode does not close it.
  def marketing_admin_access?
    MarketingAdmin.allowed?(marketing_admin_viewer, warden: request.env['warden'])
  end

  # Asking who is signed in can itself end the request: when the session
  # belongs to somebody Devise no longer lets in (archived since they signed
  # in, say), Warden signs them out and throws towards the sign-in page. That
  # redirect would tell them something answers at this address, so the throw
  # is caught here and read as what it means — nobody is signed in.
  def marketing_admin_viewer
    viewer = nil
    refused = catch(:warden) do
      viewer = true_user

      nil
    end

    viewer if refused.nil?
  end

  def require_marketing_admin_access!
    return if marketing_admin_access?

    # Raised for every format, so the answer is produced by the same code
    # that answers an address nothing routes: byte for byte the same page.
    raise ActionController::RoutingError, I18n.t('not_found')
  end

  # The same gate, for the very front of the callback chain. An operator in
  # the middle of a support session is the one visitor it steps aside for:
  # the support-session rule has to see every write a session attempts,
  # refuse it and write its audit row (SupportImpersonationGuard). The gate
  # above runs again afterwards and still answers that operator with a 404
  # unless they are on the list themselves.
  #
  # Two methods rather than one callback declared twice: Rails keeps a single
  # copy of a callback per name, so the second declaration would silently
  # replace the first.
  def hide_marketing_admin_from_strangers!
    return if support_impersonation? && marketing_admin_viewer.present?

    require_marketing_admin_access!
  end
end
