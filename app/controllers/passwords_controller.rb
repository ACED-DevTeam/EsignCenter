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

    # After `super`, not inside its block: Devise yields before it signs the
    # person in, and there is no session to note anything in until it has.
    note_password_reset(resource)
  end

  private

  # For the private marketing page only (MarketingAdmin::MailboxProof): a
  # reset that went through was finished from a link mailed to the address
  # minutes ago, which is the freshest proof of a mailbox there is. Only when
  # the reset also signed the person in (it does not for a two-factor login),
  # and only for an address on that page's list.
  def note_password_reset(user)
    return unless user&.errors&.empty? && warden.authenticated?(:user) && warden.user(:user) == user

    MarketingAdmin::MailboxProof.record!(warden, user, MarketingAdmin::MailboxProof::PASSWORD_RESET)
  end

  def after_resetting_password_path_for(_)
    new_session_path(resource_name)
  end
end
