# frozen_string_literal: true

# Seats bought, seats sent again, seats handed back.
#
# `create` is the second half of adding a seat to a paid account: the admin has
# been shown what Stripe will charge today for the rest of this billing period
# and this is the click that agrees to it. The order matters and never changes
# — the money moves FIRST, and only a subscription that Stripe says now bills
# for the extra seat gets an invitation written against it. A seat that was
# not paid for is never promised to anybody.
#
# Everything happens inside the account's row lock (StripeBilling::Linker), so
# a webhook applying a cancellation, a second admin buying a seat and this
# request cannot interleave.
class AccountInvitesController < ApplicationController
  before_action :authorize_account_management!
  before_action :load_invite, only: %i[destroy resend]

  # Nothing was reserved and nothing was charged: the seat costs what it costs
  # and the admin can try again in a moment.
  rescue_from Stripe::StripeError, StripeBilling::ListIncomplete do |e|
    ErrorReport.error(e, account_id: current_account.id)

    redirect_to settings_users_path, alert: I18n.t('billing_provider_unreachable')
  end

  rescue_from ActiveRecord::LockWaitTimeout do |e|
    ErrorReport.warning("seat lock wait timed out: #{e.message}", account_id: current_account.id)

    redirect_to settings_users_path, alert: I18n.t('billing_provider_unreachable')
  end

  def create
    offer = verified_offer

    return redirect_to settings_users_path, alert: I18n.t('seat_offer_expired') if offer.nil?

    row = Plans.billing_account(current_account).account_subscription

    return redirect_to settings_users_path, alert: I18n.t('seat_offer_stale') unless purchasable?(row, offer)

    result = buy_seat_and_invite(row, offer)

    respond_to_purchase(result)
  rescue AccountInvites::AlreadyInvited, AccountInvites::InvalidEmail, ActiveRecord::RecordInvalid => e
    # Caught before Stripe is asked for anything, so no seat was bought.
    redirect_to settings_users_path, alert: e.message
  end

  def destroy
    AccountInvites.revoke!(@invite)

    redirect_back fallback_location: settings_users_path, notice: I18n.t('invitation_has_been_cancelled')
  end

  def resend
    AccountInvites.resend!(@invite)

    redirect_back fallback_location: settings_users_path, notice: I18n.t('invitation_has_been_sent_again')
  end

  private

  def authorize_account_management!
    authorize!(:manage, current_account)
  end

  def load_invite
    @invite = current_account.account_invites.pending.find(params[:id])
  end

  # The offer the browser is handing back, exactly as this server minted it.
  # Signed, so the seat count and the price cannot be edited in the form, and
  # short-lived, so a price nobody agreed to within the quarter-hour is
  # re-quoted rather than charged.
  def verified_offer
    offer = Rails.application.message_verifier(:seat_add).verify(params[:offer].to_s).with_indifferent_access

    # Signed by us, but signed for another account: never act on it here.
    return nil if offer[:account_id].to_i != current_account.id

    offer
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  # Is the subscription still the one that was priced? A cancellation, a
  # change of plan or another seat bought in another tab all make the quoted
  # amount a lie, and the answer is to re-quote rather than to charge.
  def purchasable?(row, offer)
    BillingLifecycle.seats_purchasable?(row) &&
      row.stripe_subscription_id == offer[:subscription_id] &&
      row.stripe_item_id == offer[:item_id] &&
      row.quantity == offer[:quantity_after].to_i - 1
  end

  # Money first, invitation second, both under the row lock. Returns the
  # invitation, or the symbol that says what stopped it.
  def buy_seat_and_invite(row, offer)
    quantity_after = offer[:quantity_after].to_i
    email = AccountInvites.normalize_email(offer[:email])

    StripeBilling::Linker.with_account_lock(row) do
      # The lock re-read the row: whatever a webhook wrote a moment ago wins.
      next :stale unless purchasable?(row, offer)

      # Refuse a duplicate BEFORE the card is touched: a seat bought for an
      # invitation that cannot be written is money taken for nothing.
      AccountInvites.assert_invitable!(current_account, email)

      subscription = BillingLifecycle.add_seat!(row, quantity_after:,
                                                     idempotency_key: seat_key(row, quantity_after, email))

      next :pending_update if BillingLifecycle.pending_update?(subscription)

      StripeBilling::Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)

      AccountInvites.reserve!(account: current_account, email:, role: offer[:role],
                              invited_by: current_user, seats_bought: quantity_after)
    end
  end

  def respond_to_purchase(result)
    case result
    when :stale
      redirect_to settings_users_path, alert: I18n.t('seat_offer_stale')
    when :pending_update
      # Stripe parked the change because the card needs another step. Nothing
      # was reserved, and the customer is sent to the one page that can finish
      # it rather than left guessing.
      redirect_to settings_users_path, alert: I18n.t('seat_add_needs_payment_action')
    else
      AccountInvites.deliver!(result)

      redirect_to settings_users_path, notice: I18n.t('user_has_been_invited')
    end
  end

  # One seat per click, however many times the button is pressed: the key
  # names the row, the quantity being bought and who it is for.
  def seat_key(row, quantity_after, email)
    "seat-add:#{row.id}:#{quantity_after}:#{Digest::SHA256.hexdigest(email)[0, 16]}"
  end
end
