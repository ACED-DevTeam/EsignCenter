# frozen_string_literal: true

class PasswordsController < Devise::PasswordsController
  # rubocop:disable Rails/LexicallyScopedActionFilter
  skip_before_action :require_no_authentication, only: %i[edit update]
  # rubocop:enable Rails/LexicallyScopedActionFilter

  around_action :with_browser_locale

  class Current < ActiveSupport::CurrentAttributes
    attribute :user
  end

  def create
    # Never reveal whether the email exists: an unknown address gets the same
    # "instructions sent" answer as a known one.
    super do |resource|
      resource.errors.clear
    end
  end

  def update
    super do |resource|
      Current.user = resource
    end
  end

  private

  def after_resetting_password_path_for(_)
    new_session_path(resource_name)
  end
end
