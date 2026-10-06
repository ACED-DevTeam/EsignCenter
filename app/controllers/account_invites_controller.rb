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
  # How much higher than the quoted amount a fresh preview may come back
  # before the charge is refused. Stripe prorates by the SECOND, so the
  # amount ticks down while somebody reads the confirm screen and can tick up
  # by a penny or two at the edges of its rounding. Refusing on an exact
  # mismatch turned an honest slow click into "please try again"; what must
  # never happen is charging materially MORE than was agreed, and a renewal
  # falling inside the offer's quarter-hour moves it by a whole period, not
  # by two cents.
  SEAT_PRICE_TOLERANCE_CENTS = 2

  before_action :authorize_account_administration!
  before_action :authorize_invite_management!
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

    respond_to_purchase(result, offer)
  rescue AccountInvites::AlreadyInvited, AccountInvites::InvalidEmail,
         ActiveRecord::RecordInvalid, ActiveModel::ValidationError => e
    # Every one of these is raised BEFORE Stripe is asked for anything, so no
    # seat was bought. `validate!` on an unsaved record raises the ActiveModel
    # flavour, not the ActiveRecord one — a role that has since been retired
    # used to come out of here as a 500.
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

  # Authorized on the INVITATION, per action, rather than on the account:
  # buying a seat is a write and has to be refused when the account is frozen
  # or the admin has lost their own seat. `authorize!(:manage, current_account)`
  # never was — a `cannot :create` rule is not relevant to a `:manage`
  # question, so a suspended account could charge its card for a seat
  # (lib/ability.rb).
  # The same gate the users page carries: only an administrator who still
  # holds a seat gets this far, and the per-action check below then decides
  # whether the invitation itself may be written.
  def authorize_account_administration!
    authorize!(:administer, current_account)
  end

  def authorize_invite_management!
    case action_name
    when 'create' then authorize!(:create, AccountInvite.new(account: current_account))
    when 'destroy' then authorize!(:destroy, AccountInvite.new(account: current_account))
    else authorize!(:update, AccountInvite.new(account: current_account))
    end
  end

  # `destroy` reaches one row that `resend` must not (checkpoint 7, P5): a
  # PARKED purchase, waiting for a card step that may never be finished. It is
  # listed on the users page as "Awaiting payment" and an admin can cancel it
  # — but there is nothing to send again, because nothing was ever sent, so
  # `resend` keeps looking only at invitations that really are pending and
  # answers 404 for a parked row exactly as it does for one that has lapsed.
  def load_invite
    scope = action_name == 'destroy' ? cancellable_invites : current_account.account_invites.pending

    @invite = scope.find(params[:id])
  end

  def cancellable_invites
    invites = current_account.account_invites

    invites.pending.or(invites.payment_pending)
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
  #
  # The account's row lock is held from the moment Stripe agrees to the extra
  # seat until the invitation that fills it is written, so the hourly sweep
  # that hands unoccupied seats back can never catch the half-finished
  # picture in between and take back what was just paid for. `changing_seats`
  # says the same thing to this thread: applying Stripe's answer must not
  # start a hand-back of the seat being bought.
  def buy_seat_and_invite(row, offer)
    quantity_after = offer[:quantity_after].to_i
    email = AccountInvites.normalize_email(offer[:email])

    BillingLifecycle.changing_seats do
      StripeBilling::Linker.with_account_lock(row) do
        # The lock re-read the row: whatever a webhook wrote a moment ago wins.
        next :stale unless purchasable?(row, offer)

        # Everything that could refuse the invitation is asked BEFORE the card
        # is touched — a duplicate address, a role that is no longer a role, a
        # token that will not save — because a seat bought for an invitation
        # that cannot be written is money taken for nothing.
        AccountInvites.assert_invitable!(current_account, email)

        invite = AccountInvites.build(account: current_account, email:, role: offer[:role],
                                      invited_by: current_user)
        invite.validate!

        # A seat that became free between the quote and this click is a seat
        # that is already paid for, and charging for it again would be taking
        # money for something the customer owns (checkpoint 7, B4). It happens
        # when a hand-back failed — a member was archived while Stripe was
        # unreachable, so the subscription still bills the higher number — and
        # the honest answer is to fill the seat rather than buy a second one.
        next save_bought_invite!(invite) if seat_already_paid_for?(row)

        # And the price is asked again, a moment before it is charged: a
        # renewal can fall inside the quarter-hour the offer is good for, and
        # nobody may be charged an amount they were not shown.
        next :repriced unless quoted_price?(row, offer)

        seat_change = { quantity_after:, idempotency_key: seat_key(row, offer),
                        proration_date: offer[:proration_date].to_i }
        subscription = BillingLifecycle.add_seat!(row, **seat_change)

        next park_purchase!(invite, subscription, quantity_after) if BillingLifecycle.pending_update?(subscription)

        StripeBilling::Linker.apply_current!(row, row.stripe_subscription_id, event_at: Time.current)

        # Stripe answered, but did the subscription actually MOVE? An
        # idempotency key replayed from an earlier request answers 200 with
        # the OLD subscription and charges nothing, and reserving on the
        # strength of that answer would hand out a seat nobody bought.
        next unmoved_quantity(row, quantity_after) unless row.quantity == quantity_after

        save_bought_invite!(invite)
      end
    end
  end

  # Is this still the purchase the customer agreed to? A different currency
  # or a different seat count is a different purchase outright; a higher
  # amount is the renewal boundary. Anything at or below the quoted amount is
  # charged at the fresh (lower) number — nobody is worse off than the screen
  # they said yes to.
  def quoted_price?(row, offer)
    quote = BillingLifecycle.preview_seat_addition(row, quantity_after: offer[:quantity_after].to_i,
                                                        proration_date: offer[:proration_date].to_i)

    return false if quote[:currency].to_s != offer[:currency].to_s
    return false if quote[:quantity_after].to_i != offer[:quantity_after].to_i

    quote[:amount_cents].to_i - offer[:amount_cents].to_i <= SEAT_PRICE_TOLERANCE_CENTS
  end

  # Is there a seat sitting there paid for? Occupancy counts people and the
  # invitations holding seats for people; a subscription billing for more than
  # that has one going spare. Asked inside the lock, so the answer cannot have
  # changed by the time the invitation is written.
  def seat_already_paid_for?(row)
    Accounts.seat_occupancy(current_account) < row.quantity
  end

  # Stripe parked the change: the card needs a second step, nothing has been
  # charged, and the subscription still bills the old number. The invitation is
  # written PARKED rather than thrown away (checkpoint 7, B1) — it holds no
  # seat, goes to nobody, and cannot be accepted — so that the customer
  # finishing that step in Stripe's own portal ends with the invitation they
  # paid for instead of a seat handed silently back.
  #
  # Saved in a savepoint of its own for the same reason the bought one is: a
  # row that will not insert must not take anything else down with it, and the
  # customer is no worse off than they were before this change existed.
  def park_purchase!(invite, subscription, quantity_after)
    ApplicationRecord.transaction(requires_new: true) do
      AccountInvites.park!(invite, quantity: quantity_after,
                                   expires_at: BillingLifecycle.pending_update_expires_at(subscription))
    end

    :pending_update
  rescue ActiveRecord::ActiveRecordError => e
    ErrorReport.error(e, account_id: current_account.id)

    :pending_update
  end

  def unmoved_quantity(row, quantity_after)
    ErrorReport.warning("seat add on account #{current_account.id} was answered without moving the " \
                        "quantity (asked for #{quantity_after}, subscription still bills #{row.quantity}); " \
                        'nothing reserved', account_id: current_account.id)

    :stale
  end

  # The card has been charged by the time this runs, so a failure here is not
  # "nothing happened". It is saved in a savepoint of its own so a refused
  # INSERT cannot take the subscription update down with it, and if it still
  # will not save the customer is told the truth and a person is put on it.
  #
  # What happens next needs no hands: nobody occupies the seat, so the hourly
  # sweep (BillingLifecycle.reconcile_seats!) takes it back off the
  # subscription within the hour. The proration already invoiced stays
  # invoiced — a reduction never refunds mid-cycle (D43) — and inviting the
  # person again simply buys the seat again.
  def save_bought_invite!(invite)
    ApplicationRecord.transaction(requires_new: true) { invite.save! }

    invite
  rescue ActiveRecord::ActiveRecordError => e
    ErrorReport.error(e, account_id: current_account.id)
    OperatorAlert.deliver(
      subject: "seat charged but invitation not saved on account #{current_account.id}",
      body: "The subscription now bills for the extra seat and the invitation to #{invite.email} " \
            "could not be written: #{e.class} #{e.message}. Nothing needs doing by hand: nobody " \
            'occupies that seat, so the hourly seat sweep takes it back off the subscription within ' \
            'the hour. The proration already invoiced is not refunded (D43), and inviting them again ' \
            'buys the seat again.'
    )

    :charged_without_invite
  end

  def respond_to_purchase(result, offer)
    case result
    when :stale
      redirect_to settings_users_path, alert: I18n.t('seat_offer_stale')
    when :repriced
      redirect_to settings_users_path, alert: I18n.t('seat_add_price_changed')
    when :charged_without_invite
      redirect_to settings_users_path, alert: I18n.t('seat_add_charged_without_invite')
    when :pending_update
      # Stripe parked the change because the card needs another step. Nothing
      # has been charged and no seat exists yet — but the invitation is
      # remembered, so finishing the step really does finish the job, and the
      # message says so rather than asking them to start again.
      redirect_to settings_users_path,
                  alert: I18n.t('seat_add_needs_payment_action',
                                email: AccountInvites.normalize_email(offer[:email]))
    else
      AccountInvites.deliver!(result)

      redirect_to settings_users_path, notice: I18n.t('user_has_been_invited')
    end
  end

  # One seat per click, however many times the button is pressed. The nonce
  # is what makes it one CLICK rather than one address: keyed on the email,
  # inviting somebody, cancelling and inviting them again reused the key, and
  # Stripe replayed the first answer — no charge, no quantity change, and an
  # invitation reserved against a seat nobody had bought. The nonce is minted
  # with the offer and travels inside its signature, so a double-clicked
  # button still shares one key.
  def seat_key(row, offer)
    "seat-add:#{row.id}:#{offer[:quantity_after]}:#{offer[:nonce]}"
  end
end
