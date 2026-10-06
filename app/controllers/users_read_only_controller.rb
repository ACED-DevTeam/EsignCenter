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
  before_action :refuse_while_frozen!
  before_action :load_user

  def create
    # A read-only admin can administer nothing, so parking one is a removal of
    # administrator capability like archiving or demoting is: asked and written
    # under the account's row lock so two admins parking each other at the same
    # moment cannot both be told there is a second one left
    # (Accounts.with_last_admin_guard).
    Accounts.with_last_admin_guard(@user) { @user.update!(read_only_at: Time.current) }

    # Outside the lock: handing the seat back can call Stripe, and a slow
    # payment provider must not hold an account row.
    AccountInvites.release_seat_for(current_account)

    redirect_back fallback_location: settings_users_path, notice: I18n.t('user_is_now_read_only')
  rescue Accounts::LastAdminError
    redirect_to settings_users_path, alert: I18n.t('last_admin_cannot_be_removed')
  end

  def destroy
    # Their own read-only mark is the one thing they may not lift: everybody
    # can manage their own user row (that is how a password gets changed), and
    # without this the member an admin just parked could simply un-park
    # themselves.
    if @user == current_user && current_user.read_only?
      return redirect_to settings_users_path, alert: I18n.t('read_only_cannot_restore_self')
    end

    Quotas.with_creation_lock(current_account) do
      Quotas.assert_seat_available!(current_account)

      @user.update!(read_only_at: nil)
    end

    redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_full_access_again')
  rescue Quotas::SeatLimitReached => e
    redirect_to settings_users_path, alert: e.localized_message
  end

  private

  # `:administer` on the account, like the users page itself; the two buttons
  # are then authorized on the PERSON they act on.
  def authorize_account_management!
    authorize!(:administer, current_account)
  end

  # Both buttons WRITE — one of them all the way out to Stripe, to hand a seat
  # back — and a frozen account writes nothing, however much its admin can
  # still read. The account-level ability cannot express this on its own: a
  # suspended admin legitimately keeps `:administer` so they can see who holds
  # a seat while they sort the payment out.
  def refuse_while_frozen!
    return unless AccountStates.read_only?(current_account)

    redirect_to settings_users_path, alert: I18n.t('account_suspended_alert')
  end

  # Nested under the user, so the id is in :user_id. Scoped to the account
  # before it is authorized: another account's user is a 404, not a refusal.
  def load_user
    @user = current_account.users.find(params[:user_id])

    authorize!(:update, @user)
  end
end
