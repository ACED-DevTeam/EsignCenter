# frozen_string_literal: true

module LaunchGates
  extend ActiveSupport::Concern

  # Future registration and billing controllers should use these as before actions.
  private

  def require_registration_enabled!
    head :not_found unless Docuseal.registration_enabled?
  end

  def require_billing_enabled!
    head :not_found unless Docuseal.billing_enabled?
  end
end
