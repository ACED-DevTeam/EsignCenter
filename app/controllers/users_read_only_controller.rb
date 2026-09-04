# frozen_string_literal: true

# Who holds a seat, decided by the admin (Session 7 Phase B, D43).
#
# When a paid account drops back to the free plan it has one seat and probably
# several people. Nobody is deleted: everyone except one admin is marked
# read-only, and this is the page's two buttons for changing that afterwards.
#
#   create  — "Make read-only": hand the seat back. On a live subscription
#             that also tells Stripe to bill one fewer at renewal.
#   destroy — "Give full access": take a seat. Refused when there is none free,
#             with the same sentence every other seat refusal uses.
class UsersReadOnlyController < ApplicationController
  before_action :authorize_account_management!
  before_action :load_user

  def create
    return redirect_to settings_users_path, alert: I18n.t('last_admin_cannot_be_removed') if Accounts.last_admin?(@user)

    @user.update!(read_only_at: Time.current)

    AccountInvites.release_seat_for(current_account)

    redirect_back fallback_location: settings_users_path, notice: I18n.t('user_is_now_read_only')
  end

  def destroy
    Quotas.with_creation_lock(current_account) do
      Quotas.assert_seat_available!(current_account)

      @user.update!(read_only_at: nil)
    end

    redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_full_access_again')
  rescue Quotas::SeatLimitReached => e
    redirect_to settings_users_path, alert: e.localized_message
  end

  private

  def authorize_account_management!
    authorize!(:manage, current_account)
  end

  # Nested under the user, so the id is in :user_id. Scoped to the account
  # before it is authorized: another account's user is a 404, not a refusal.
  def load_user
    @user = current_account.users.find(params[:user_id])

    authorize!(:update, @user)
  end
end
