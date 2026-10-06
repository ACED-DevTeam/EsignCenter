# frozen_string_literal: true

# Devise's confirmation endpoints. The resend form and the resend POST only
# make sense once self-serve registration exists — every internal creation
# path calls skip_confirmation! — so until REGISTRATION_ENABLED is on they
# answer 404 like every other registration surface: no email-enumeration form
# and no arbitrary resend trigger on a product with no public signup.
#
# The token link itself (`show`) is always served. Email changes wait for it
# (config.reconfirmable) whether or not sign-up is open, and it enumerates
# nothing: only the holder of a live token can do anything with it. With the
# switch off a link that does not work is a plain 404, so the resend form
# Devise would render is never shown there either.
class ConfirmationsController < Devise::ConfirmationsController
  include LaunchGates

  before_action :require_registration_enabled!, except: :show

  def show
    return super if Docuseal.registration_enabled?

    self.resource = resource_class.confirm_by_token(params[:confirmation_token])

    return head :not_found if resource.errors.any?

    set_flash_message!(:notice, :confirmed)
    redirect_to after_confirmation_path_for(resource_name, resource)
  end
end
