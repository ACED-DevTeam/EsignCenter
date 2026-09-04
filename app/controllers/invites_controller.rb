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
#     to be signed in AS THE INVITED ADDRESS, restates in plain words what is
#     about to happen, and only then offers the one button that does it.
#
# Which of the two it is, is asked FRESH on every request, from the invited
# address (AccountInvites.verdict_for) — never from the collision_user_id the
# row was written with. The world moves inside the week a link is good for:
# the invitee can sign themselves up in the meantime (review B1), and the
# person the column names can change their own email (review B2). The stored
# column survives only as a hint for the invitation email's copy.
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

    return render_dead_end if dead_end?
    return redirect_to_sign_in if @move_offer && current_user.nil?

    # Signed in, but as somebody else: the page still explains the offer, and
    # says whose it is.
    @error = I18n.t('invite_sign_in_as_other_user', email: @invite.email) if @move_offer && !@signed_in_as_invitee

    render :show
  end

  def create
    return render :unavailable, status: :gone unless @invite

    return render_dead_end if dead_end?

    @move_offer ? accept_move : accept_new_user
  rescue AccountInvites::NoLongerOpen => e
    # Something changed between the page and the button: cancelled, lapsed,
    # or the seat is gone. The reason is the sentence, and 410 is the honest
    # status for a link that no longer leads anywhere.
    unavailable(e.message)
  rescue AccountInvites::WrongInvitee => e
    # The address changed hands under the invitation, between this page being
    # drawn and the button being pressed. A sentence, on the page they are
    # already looking at — never the unique index's "already been taken".
    @error = e.message

    render :show, status: :unprocessable_content
  end

  private

  # The three ways a live invitation still leads nowhere. Asked identically on
  # the page and on the button, so neither can offer what the other refuses.
  def dead_end?
    frozen_team? || @verdict == :closed_login || @verdict == :member
  end

  def render_dead_end
    return unavailable(I18n.t('invite_account_frozen')) if frozen_team?
    return unavailable(I18n.t('invite_address_closed_login')) if @verdict == :closed_login

    release_to_member
  end

  # They are already in the team — they accepted another copy of this
  # invitation, or an admin created them by hand. There is nothing to accept,
  # and the seat this invitation is still holding goes back the ordinary way
  # (cancelled here, one fewer at renewal — D43, no mid-cycle refund).
  def release_to_member
    AccountInvites.revoke!(@invite)

    unavailable(I18n.t('invite_already_member', team: @account.name))
  end

  # A team that cannot write cannot take on people either: an account frozen
  # for a failed payment (or archived) would otherwise gain a member — or a
  # whole other account's documents — while nobody in it can act.
  def frozen_team?
    @invite.present? && AccountStates.read_only?(@account)
  end

  # A dead link deserves a sentence saying which way it died.
  def unavailable(reason)
    @unavailable_reason = reason

    render :unavailable, status: :gone
  end

  # Only a live invitation is ever loaded: expired, cancelled and already
  # accepted are all the same answer to whoever is holding the link.
  def load_invite
    invite = AccountInvite.find_by_token(params[:token])

    @invite = invite if invite&.pending?
    @account = @invite&.account

    return if @invite.nil?

    # Asked from the address, on every request. `@holder` is whoever owns the
    # invited address right now — the person the page is talking about, and
    # the only person who may press the button.
    @verdict = AccountInvites.verdict_for(@invite)
    @holder = AccountInvites.holder_for(@invite)
    @move_offer = @verdict == :move
    @signed_in_as_invitee = signed_in_as_invitee?
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
    return require_matching_sign_in unless @signed_in_as_invitee

    moved = AccountInvites.accept_move!(@invite, user: current_user)

    # The move threw away every credential the person's old account had cut,
    # remember-me included (Accounts::MoveUser#revoke_credentials!), and bumped
    # `users.session_version`, which ends every live browser session they had
    # — this one included (User#authenticatable_salt).
    #
    # That is deliberate, and this line is the one exception to it. This
    # browser is the one that just asked for the move, so it is the one
    # credential that should survive: `bypass_sign_in` re-serialises the person
    # into the session, which mints a cookie carrying the NEW session version
    # and the account they now belong to. Every other browser they left signed
    # in somewhere — including one on a machine nobody here can see — is
    # holding the old number and is signed out on its next request.
    #
    # The reload is load-bearing rather than tidy: the cookie is stamped from
    # the object in hand, so it has to be the object the move actually wrote.
    # Serialising a stale copy would mint a cookie carrying the OLD version
    # and sign this browser straight back out again.
    bypass_sign_in(moved.reload)

    redirect_to root_path, notice: I18n.t('invite_welcome_to_team', team: @account.name)
  rescue Accounts::MoveUser::Refused => e
    @error = e.message

    render :show, status: :unprocessable_content
  end

  # The invited ADDRESS, not a stored user id. An id says who held the
  # address when the invitation was written; a week later it can be somebody
  # at a different address entirely, and honouring it moved that person — and
  # every document in their account — into a team that never invited them
  # (review B2). AccountInvites.accept_move! asks the same question again
  # inside the row lock.
  def signed_in_as_invitee?
    current_user.present? &&
      AccountInvites.normalize_email(current_user.email) == AccountInvites.normalize_email(@invite.email)
  end

  # Anonymous: send them to sign in and come straight back here. Signed in as
  # somebody else: say so, rather than silently doing nothing.
  def require_matching_sign_in
    return redirect_to_sign_in if current_user.nil?

    @error = I18n.t('invite_sign_in_as_other_user', email: @invite.email)

    render :show, status: :unprocessable_content
  end

  def redirect_to_sign_in
    store_location_for(:user, invite_path(token: params[:token]))

    redirect_to new_user_session_path, alert: I18n.t('invite_sign_in_required', email: @invite.email)
  end
end
