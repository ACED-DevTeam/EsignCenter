# frozen_string_literal: true

class UsersController < ApplicationController
  # How long a seat-addition offer is good for. The customer is being shown a
  # price that Stripe calculated for this minute; a stale offer is refused and
  # re-priced rather than charged.
  SEAT_OFFER_TTL = 15.minutes

  before_action :authorize_account_management!

  load_and_authorize_resource :user, only: %i[index edit update destroy]

  before_action :build_user, only: %i[new create]
  authorize_resource :user, only: %i[new create]

  helper_method :seats_are_invited?

  # Stripe could not be reached while pricing a seat. Nothing was reserved and
  # nothing was charged; the page says so rather than 500ing.
  rescue_from Stripe::StripeError, StripeBilling::ListIncomplete do |e|
    ErrorReport.error(e, account_id: current_account.id)

    redirect_to settings_users_path, alert: I18n.t('billing_provider_unreachable')
  end

  def index
    @users =
      if params[:status] == 'archived'
        @users.archived.where.not(role: 'integration')
      elsif params[:status] == 'integration'
        @users.active.where(role: 'integration')
      else
        @users.active.where.not(role: 'integration')
      end

    @users = @users.preload(account: :account_accesses).where(account: current_account).order(id: :desc)

    # Seats held for people who have not arrived yet. They belong on this page
    # because they are the other half of "who is in this account" — and so do
    # PARKED purchases (checkpoint 7, P5): a seat whose card step was never
    # finished holds nothing and was mailed to nobody, but an admin has to be
    # able to see it and cancel it rather than wait out Stripe's deadline.
    if params[:status].blank?
      invites = current_account.account_invites
      @pending_invites = invites.pending.or(invites.payment_pending).order(id: :desc)
    end

    respond_to do |format|
      format.html do
        @pagy, @users = pagy(@users)
      end

      if current_ability.can?(:administer, current_account)
        format.csv do
          send_data Users.generate_csv(@users), filename: "users-#{Time.current.iso8601}.csv", type: 'text/csv'
        end
      end
    end
  end

  def new; end

  def edit; end

  # Adding somebody to the account. Which of two things that means depends on
  # who is paying (Session 7 Phase B):
  #
  #   * an internal or operator account, or bringing an ARCHIVED colleague
  #     back — the user row is created (or un-archived) on the spot, exactly
  #     as it always was;
  #   * a customer account — an INVITATION is written instead. It holds the
  #     seat, it is sent by email, and the person themselves creates their
  #     login when they accept it. On a paid account with no free seat the
  #     admin is shown what the extra seat costs today and has to agree to it
  #     before anything is reserved.
  def create
    existing_user = User.accessible_by(current_ability).find_by(email: @user.email)

    return refuse_in_modal(I18n.t('already_exists')) if existing_user && !reactivatable?(existing_user)

    return create_user_now(existing_user) if existing_user || !seats_are_invited?

    invite_to_seat
  end

  def update
    return redirect_to settings_users_path, notice: I18n.t('unable_to_update_user') if Docuseal.demo?

    attrs = update_attributes
    # Read BEFORE the move: the account that can be stranded is the one this
    # person is leaving, and by the time the move has been assigned @user
    # already answers with the destination.
    leaving_account_id = @user.account_id

    move_to_requested_account!

    # A changed address waits in `unconfirmed_email` until the member opens
    # the link mailed to the NEW address (config.reconfirmable): an admin can
    # ask for the change, never complete it. The link is mailed once, by the
    # job below, rather than a second time by Devise's own callback.
    @user.skip_confirmation_notification!

    if update_user(attrs, leaving_account_id)
      if @user.try(:pending_reconfirmation?) && @user.previous_changes.key?(:unconfirmed_email)
        SendConfirmationInstructionsJob.perform_async('user_id' => @user.id)

        redirect_back fallback_location: settings_users_path,
                      notice: I18n.t('a_confirmation_email_has_been_sent_to_the_new_email_address')
      else
        redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_been_updated')
      end
    else
      render turbo_stream: turbo_stream.replace(:modal, template: 'users/edit'), status: :unprocessable_content
    end
  rescue Quotas::SeatLimitReached => e
    redirect_to settings_users_path, alert: e.localized_message
  rescue Accounts::LastAdminError
    # An account with no administrator can never invite anyone, change a role
    # or fix its own billing again: archiving the last admin, demoting them, or
    # moving them out is refused, and nothing was written (Phase B; the check
    # and the write share the account's row lock — Accounts.with_last_admin_guard).
    redirect_to settings_users_path, alert: I18n.t('last_admin_cannot_be_removed')
  end

  def destroy
    if Docuseal.demo? || @user.id == current_user.id
      return redirect_to settings_users_path, notice: I18n.t('unable_to_remove_user')
    end

    # Asked and archived under the account's row lock, so a second admin
    # archiving THIS one at the same moment cannot leave the account with
    # nobody who can administer it (Accounts.with_last_admin_guard).
    Accounts.with_last_admin_guard(@user) { @user.update!(archived_at: Time.current) }

    # Their seat goes back: the next invoice bills one fewer (D43 — a
    # reduction takes effect at renewal, there is no mid-cycle refund). Outside
    # the lock: it can call Stripe, and a slow payment provider must not hold
    # an account row.
    AccountInvites.release_seat_for(current_account)

    redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_been_removed')
  rescue Accounts::LastAdminError
    redirect_to settings_users_path, alert: I18n.t('last_admin_cannot_be_removed')
  end

  private

  # Seeing who is in the account is administrators only; editors and viewers
  # manage their own profile via ProfileController instead. This is the gate
  # on the PAGE — `:administer`, which a frozen account's admin keeps (they
  # have to be able to see who holds a seat) and which nobody else in that
  # account has, so a read-only viewer cannot read the list of pending
  # invitations. Every write beyond it is authorized on the User itself by
  # load_and_authorize_resource.
  def authorize_account_management!
    authorize!(:administer, current_account)
  end

  def role_valid?(role)
    User::ROLES.include?(role)
  end

  # Everything this request is allowed to change, after the account's own
  # rules: a person can never change their own role, their own 2FA
  # requirement or their own archived flag, and nobody sets a password here.
  # Nor their own email address: that is Profile's job, which asks for the
  # current password first (ProfileController#update_contact).
  def update_attributes
    attrs = user_params.compact_blank
    attrs = attrs.merge(user_params.slice(:archived_at)) if current_ability.can?(:create, @user)

    self_excluded = %i[password otp_required_for_login role archived_at email]

    attrs.except(*(current_user == @user ? self_excluded : %i[password]))
  end

  # Moving somebody to another account is authorized against THAT account, not
  # this one.
  def move_to_requested_account!
    return if params.dig(:user, :account_id).blank?

    account = Account.accessible_by(current_ability).find(params.dig(:user, :account_id))

    authorize!(:manage, account)

    @user.account = account
  end

  # Could this edit take administrator capability away from the account this
  # person is in? All three ways it can happen through this door: archiving
  # them, demoting them to a role that cannot administer anything, and moving
  # them to another account altogether.
  #
  # It deliberately does NOT ask whether they are the last administrator —
  # that question is only worth anything under the account's row lock, and
  # update_user asks it there (Accounts.with_last_admin_guard).
  def removes_admin_capability?(attrs, account_id)
    archiving = attrs.key?(:archived_at) && attrs[:archived_at].present?
    demoting = attrs[:role].present? && attrs[:role] != User::ADMIN_ROLE
    moving = @user.account_id != account_id

    archiving || demoting || moving
  end

  # Does adding a person to this account go through an invitation? Every
  # customer account: seats are money there, and the seat has to be held from
  # the moment it is paid for. Internal and operator accounts have no seats to
  # hold and create the user outright.
  def seats_are_invited?
    Plans.key_for(current_account) != Plans::INTERNAL
  end

  # The original path, unchanged: an internal/operator invitation, or an
  # archived colleague coming back. The seat check and the save share the
  # account's creation lock so two clicks cannot both take the last seat.
  def create_user_now(existing_user)
    saved = Quotas.with_creation_lock(current_account) do
      Quotas.assert_seat_available!(current_account)

      @user = reactivate(existing_user) if existing_user

      @user.password = SecureRandom.hex if @user.password.blank?
      @user.role = User::ADMIN_ROLE unless role_valid?(@user.role)
      @user.skip_confirmation!

      @user.save
    end

    if saved
      UserMailer.invitation_email(@user).deliver_later!

      redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_been_invited')
    else
      render turbo_stream: turbo_stream.replace(:modal, template: 'users/new'), status: :unprocessable_content
    end
  rescue Quotas::SeatLimitReached => e
    redirect_to settings_users_path, alert: e.localized_message
  end

  # A customer account: write the invitation, which is what holds the seat.
  def invite_to_seat
    invite = AccountInvites.reserve!(account: current_account, email: invite_email,
                                     role: invite_role, invited_by: current_user)

    AccountInvites.deliver!(invite)

    redirect_back fallback_location: settings_users_path, notice: I18n.t('user_has_been_invited')
  rescue Quotas::SeatLimitReached => e
    offer_extra_seat(e)
  rescue AccountInvites::AlreadyInvited, AccountInvites::InvalidEmail => e
    refuse_in_modal(e.message)
  rescue ActiveRecord::RecordInvalid => e
    # The messages only, not the full sentences: the form's own error renderer
    # puts the field name in front of whatever it is given, and "Email Email
    # is invalid" helps nobody.
    refuse_in_modal(e.record.errors[:email].to_sentence.presence || e.record.errors.full_messages.to_sentence)
  end

  # No free seat. On a paid account that we actually bill through Stripe, that
  # is not a refusal — it is an offer: here is what one more seat costs for the
  # rest of this period, and nothing is reserved or charged until it is
  # confirmed. Everywhere else (a free account, an operator-granted plan, a
  # child account whose parent pays) the old refusal stands.
  def offer_extra_seat(error)
    row = billing_row

    return redirect_to settings_users_path, alert: error.localized_message unless seat_offer_possible?(row)

    # The nonce is what makes the Stripe idempotency key name this CLICK
    # rather than this address: without it, inviting somebody, cancelling and
    # inviting them again reused the key and Stripe replayed the first answer
    # (AccountInvitesController#seat_key).
    # The proration instant is minted HERE, with the offer, and the charge is
    # made from the same one: preview and invoice then describe the same slice
    # of the billing period however long the customer takes to decide.
    @seat_offer = BillingLifecycle.preview_seat_addition(row, proration_date: Time.current.to_i)
                                  .merge(email: invite_email, role: invite_role, account_id: current_account.id,
                                         nonce: SecureRandom.hex(8))
    @seat_token = Rails.application.message_verifier(:seat_add)
                       .generate(@seat_offer.stringify_keys, expires_in: SEAT_OFFER_TTL)

    render turbo_stream: turbo_stream.replace(:modal, template: 'users/seat_confirm')
  end

  # A child account's admin may fill a free seat, but may never put a charge
  # on the parent's card: buying is for the account that pays.
  def seat_offer_possible?(row)
    Plans.billing_account(current_account) == current_account && BillingLifecycle.seats_purchasable?(row)
  end

  def billing_row
    Plans.billing_account(current_account).account_subscription
  end

  def invite_email
    AccountInvites.normalize_email(@user.email)
  end

  def invite_role
    role_valid?(@user.role) ? @user.role : User::ADMIN_ROLE
  end

  # Every refusal that belongs on the form itself rather than in a flash: the
  # modal comes back with the address still typed in and the reason under it.
  def refuse_in_modal(message)
    @user.errors.add(:email, message)

    render turbo_stream: turbo_stream.replace(:modal, template: 'users/new'), status: :unprocessable_content
  end

  # An edit that could cost the account an administrator is decided and
  # committed under that account's row lock, so two admins editing each other
  # at the same moment cannot both be told there is a second one left
  # (Accounts.with_last_admin_guard raises Accounts::LastAdminError, which the
  # action turns back into the refusal sentence). Every other edit — a name, a
  # 2FA requirement, a promotion — needs no lock at all.
  def update_user(attrs, leaving_account_id)
    return save_user(attrs) unless removes_admin_capability?(attrs, leaving_account_id)

    Accounts.with_last_admin_guard(@user, account_id: leaving_account_id) { save_user(attrs) }
  end

  # "Unarchive" (users/index) fills a seat exactly like an invite does, so it
  # runs the same check under the same creation lock; every other edit of an
  # archived user (a name, a role) is a plain update.
  def save_user(attrs)
    return @user.update(attrs) unless reactivating?(attrs)

    Quotas.with_creation_lock(current_account) do
      Quotas.assert_seat_available!(current_account)

      @user.update(attrs)
    end
  end

  def reactivating?(attrs)
    @user.archived_at.present? && attrs.key?(:archived_at) && attrs[:archived_at].blank?
  end

  def reactivatable?(existing_user)
    existing_user.archived_at? &&
      current_ability.can?(:manage, existing_user) && current_ability.can?(:manage, @user.account)
  end

  def reactivate(existing_user)
    existing_user.assign_attributes(@user.slice(:first_name, :last_name, :role, :account_id))
    existing_user.archived_at = nil

    existing_user
  end

  def build_user
    @user = current_account.users.new(user_params)
  end

  def user_params
    if params.key?(:user)
      permitted_params = %i[email first_name last_name password archived_at otp_required_for_login]

      permitted_params << :role if role_valid?(params.dig(:user, :role))

      params.require(:user).permit(permitted_params)
    else
      {}
    end
  end
end
