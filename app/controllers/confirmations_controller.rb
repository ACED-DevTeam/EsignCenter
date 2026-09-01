# frozen_string_literal: true

# Devise's confirmation endpoints (resend form, resend POST, token confirm)
# only make sense once self-serve registration exists — every internal
# creation path calls skip_confirmation!. Until REGISTRATION_ENABLED is on
# they answer 404 like every other registration surface, so there is no
# email-enumeration form and no arbitrary resend trigger on a product with
# no public signup.
class ConfirmationsController < Devise::ConfirmationsController
  include LaunchGates

  before_action :require_registration_enabled!
end
