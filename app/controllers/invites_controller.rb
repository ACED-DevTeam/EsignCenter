# frozen_string_literal: true

# The invitation link, opened by the person who was invited.
#
# Two situations, one page:
#
#   * a fresh address — they choose a name and a password and they are in.
#     The user row is created HERE, at accept time, so an invitation that is
#     never accepted leaves no half-made login behind.
#
#   * an address that already has an EsignCenter account (D50) — accepting is
#     a MOVE, not a sign-up: they and everything in their own account go into
#     the team. That needs proof it is really them, so the page requires them
#     to be signed in as that user, restates in plain words what is about to
#     happen, and only then offers the one button that does it.
#
# No login is required to reach the page: a fresh invitee has no account yet.
# An invitation that is expired, cancelled or already used says so on a page
# of its own with a 410 — a dead link deserves a sentence, not a 404.
class InvitesController < ApplicationController
  layout 'form'

  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_browser_locale
  before_action :load_invite

  def show
    return render :unavailable, status: :gone unless @invite
    return redirect_to_sign_in if @invite.collision? && current_user.nil?

    # Signed in, but as somebody else: the page still explains the offer, and
    # says whose it is.
    if @invite.collision? && !signed_in_as_invitee?
      @error = I18n.t('invite_sign_in_as_other_user', email: @collision_user.email)
    end

    render :show
  end

  def create
    return render :unavailable, status: :gone unless @invite

    @invite.collision? ? accept_move : accept_new_user
  end

  private

  # Only a live invitation is ever loaded: expired, cancelled and already
  # accepted are all the same answer to whoever is holding the link.
  def load_invite
    invite = AccountInvite.find_by_token(params[:token])

    @invite = invite if invite&.pending?
    @account = @invite&.account
    @collision_user = @invite&.collision_user
  end

  # The fresh path: this person has no login yet, so they make one.
  def accept_new_user
    user = AccountInvites.accept!(@invite, first_name: params[:first_name].to_s.strip,
                                           last_name: params[:last_name].to_s.strip,
                                           password: params[:password].to_s)

    sign_in(:user, user)

    redirect_to root_path, notice: I18n.t('invite_welcome_to_team', team: @account.name)
  rescue ActiveRecord::RecordInvalid => e
    @error = e.record.errors.full_messages.to_sentence

    render :show, status: :unprocessable_content
  end

  # The move path: everything they own comes with them, so the app has to be
  # sure it is them, and the account they are leaving has to be one that can
  # honestly be closed (Accounts::MoveUser refuses the rest, with a sentence).
  def accept_move
    return require_matching_sign_in unless signed_in_as_invitee?

    AccountInvites.accept_move!(@invite, user: current_user)

    redirect_to root_path, notice: I18n.t('invite_welcome_to_team', team: @account.name)
  rescue Accounts::MoveUser::Refused => e
    @error = e.message

    render :show, status: :unprocessable_content
  end

  def signed_in_as_invitee?
    current_user.present? && current_user.id == @collision_user&.id
  end

  # Anonymous: send them to sign in and come straight back here. Signed in as
  # somebody else: say so, rather than silently doing nothing.
  def require_matching_sign_in
    return redirect_to_sign_in if current_user.nil?

    @error = I18n.t('invite_sign_in_as_other_user', email: @collision_user.email)

    render :show, status: :unprocessable_content
  end

  def redirect_to_sign_in
    store_location_for(:user, invite_path(token: params[:token]))

    redirect_to new_user_session_path, alert: I18n.t('invite_sign_in_required', email: @collision_user.email)
  end
end
