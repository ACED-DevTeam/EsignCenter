# frozen_string_literal: true

# Invitations: the life of a seat that is held for somebody who has not
# arrived yet (Session 7 Phase B).
#
# The rule the whole module exists to keep: a seat is NEVER promised before it
# is available. On a free account there is one seat and it is already taken;
# on a paid account a seat is either free (the subscription already bills for
# it) or it is bought from Stripe — and only once the money has actually moved
# is the invitation written and sent. Everything that reserves goes through
# `reserve!`, which re-checks occupancy inside the account's creation lock, so
# two admins clicking at once cannot both take the last seat.
#
# Internal and operator accounts do not come through here at all: they have no
# seats to count and their invitations create the user outright
# (UsersController).
module AccountInvites
  # Raised when the invited address is already in this account, or already has
  # an invitation waiting. Carries the sentence the modal shows.
  class AlreadyInvited < StandardError; end

  # A typo. It has to be caught in the same breath as "already invited",
  # because both are asked BEFORE a seat is priced or bought: an address that
  # can never be saved must not cost anybody $10.
  class InvalidEmail < StandardError; end

  # The invitation cannot be acted on any more: somebody cancelled it, it
  # lapsed, the team it points at is frozen, or the seat it was holding is no
  # longer there. Carries the sentence the acceptance page shows.
  class NoLongerOpen < StandardError; end

  module_function

  def normalize_email(email)
    email.to_s.strip.downcase
  end

  # The user this address already belongs to somewhere else, or nil. Email is
  # unique across the whole app, so there is at most one — and if they are in
  # THIS account it is not a collision, it is an ordinary duplicate.
  def collision_user_for(email, account)
    user = User.find_by(email: normalize_email(email))

    return nil if user.nil? || user.account_id == account.id

    user
  end

  def pending_for(account, email)
    account.account_invites.pending.find_by(email: normalize_email(email))
  end

  # Write the invitation and hold the seat, or refuse. The occupancy check and
  # the insert share the billing account's creation lock — the same lock every
  # other seat-filling path takes (Quotas.with_creation_lock) — so the answer
  # cannot be stale by the time the row lands.
  #
  # `seats_bought` is the quantity the caller has just paid Stripe for: on
  # that path the seat provably exists, and re-asking "is a seat free?" would
  # race against the webhook that is applying the same change.
  def reserve!(account:, email:, role:, invited_by:, seats_bought: nil)
    email = normalize_email(email)

    Quotas.with_creation_lock(account) do
      assert_invitable!(account, email)

      Quotas.assert_seat_available!(account) if seats_bought.nil?

      invite = build(account:, email:, role:, invited_by:)
      invite.save!

      invite
    end
  end

  # The invitation row, built and tokened but not saved. The buying path needs
  # it in this state: it has to know the invitation WILL save before it puts a
  # charge on somebody's card.
  def build(account:, email:, role:, invited_by:)
    invite = account.account_invites.new(
      email: normalize_email(email), role:, invited_by:,
      collision_user: collision_user_for(email, account),
      expires_at: BillingLifecycle::INVITE_TOKEN_DAYS.days.from_now
    )

    invite.generate_token

    invite
  end

  # An address already in the account (or already invited), or one that is not
  # an address at all, is a mistake worth a sentence, not a seat. An address in
  # ANOTHER account is not: that is the "join this team" offer and it goes
  # through exactly like a fresh one.
  def assert_invitable!(account, email)
    assert_email_shape!(email)

    raise AlreadyInvited, I18n.t('already_exists') if User.where(account_id: account.id).active.exists?(email:)

    raise AlreadyInvited, I18n.t('invite_already_pending') if pending_for(account, email)
  end

  # The model's own sentence for a bad address, so the modal says exactly what
  # it says for every other address in the app ("Email is invalid") rather
  # than a second wording of the same thing.
  def assert_email_shape!(email)
    return if email.to_s.match?(AccountInvite::EMAIL_FORMAT)

    probe = AccountInvite.new(email:)
    probe.valid?

    raise InvalidEmail, probe.errors[:email].to_sentence
  end

  # The raw token exists only on the object that minted it, so it is handed
  # to the mailer explicitly: nothing that comes back out of the database can
  # rebuild an accept link.
  def deliver!(invite, raw_token = invite.raw_token)
    AccountInviteMailer.invitation(invite, raw_token).deliver_later!
  end

  # Send the same invitation again. The token is re-minted and the clock
  # restarts: the old link stops working, which is what "resend" has to mean
  # for a link that grants access to an account.
  def resend!(invite)
    raw_token = invite.generate_token
    invite.update!(expires_at: BillingLifecycle::INVITE_TOKEN_DAYS.days.from_now)

    deliver!(invite, raw_token)

    invite
  end

  # Cancel a pending invitation and hand the seat back (the next invoice bills
  # one fewer — D43, no mid-cycle refunds). Under the invitation's own lock,
  # so a cancel and an acceptance racing each other can only settle one way.
  def revoke!(invite)
    revoked = invite.with_lock do
      next false unless invite.pending?

      invite.update!(revoked_at: Time.current)

      true
    end

    return invite unless revoked

    # `released_at` is a "handled with Stripe" marker, so it is written only
    # once Stripe has actually taken the lower number. A failure leaves it
    # nil and the hourly sweep tries the same account again.
    invite.update!(released_at: Time.current) unless release_seat_for(invite.account) == :failed

    invite
  end

  # Somebody left, or lost their seat: tell Stripe the account needs fewer.
  # Safe to call for any account — it does nothing unless there is a live
  # subscription billing for more seats than are occupied. Answers with
  # BillingLifecycle's verdict (:updated / :noop / :failed).
  def release_seat_for(account)
    row = Plans.billing_account(account).account_subscription

    row ? BillingLifecycle.release_seats!(row) : :noop
  end

  # The one door every acceptance goes through.
  #
  # Between the page being rendered and the button being pressed, everything
  # can have changed: an admin cancelled the invitation, it lapsed, the
  # account was suspended for a failed payment, or the plan dropped to one
  # seat. So all of it is asked again INSIDE the invitation's row lock, and
  # the person's creation (or their move) and the "accepted" stamp happen in
  # that same transaction — a concurrent cancel can only win or lose whole,
  # never leave a member behind in an account that has no seat for them.
  def with_open_invite(invite)
    invite.with_lock do
      raise NoLongerOpen, I18n.t('invite_unavailable_hint') unless invite.pending?
      raise NoLongerOpen, I18n.t('invite_account_frozen') if AccountStates.read_only?(invite.account)

      assert_seat_for_acceptance!(invite)

      yield
    end
  end

  # Is there still a seat for the person accepting? Their own invitation is
  # the seat they are about to take, so it is not counted against them —
  # everything else is. A plan that shrank while the invitation was in the
  # post (a downgrade to the free plan's single seat) is refused here rather
  # than quietly handing the account a second full-access member.
  def assert_seat_for_acceptance!(invite)
    billing = Plans.billing_account(invite.account)

    return true if Plans.key_for(billing) == Plans::INTERNAL

    seats = Plans.seats_for(billing)

    return true if seats.nil?
    return true if Accounts.seat_occupancy(billing) - held_by(invite, billing) < seats

    raise NoLongerOpen, I18n.t('invite_no_seat_left')
  end

  # The seat this invitation is holding, which is the one the person accepting
  # is about to take and so must not be counted against them: 1 when the
  # invitation is inside the family whose seats are being counted, 0 when it
  # is not (a testing child is the same tenant but is never billed, so its
  # invitations occupy nothing).
  def held_by(invite, billing)
    Accounts.seat_account_ids(billing).include?(invite.account_id) ? 1 : 0
  end

  # A fresh invitation accepted: the person is created here, in the account
  # that invited them, with the role the invitation carried. The pending
  # invite's seat becomes their seat, so occupancy does not move.
  def accept!(invite, first_name:, last_name:, password:)
    with_open_invite(invite) do
      user = invite.account.users.new(email: invite.email, first_name:, last_name:,
                                      role: invite.role, password:)
      user.skip_confirmation!
      user.save!

      invite.update!(accepted_at: Time.current)

      user
    end
  end

  # The collision case (D50): the invitee already has an account of their own
  # and accepts by MOVING into the team, bringing everything with them.
  def accept_move!(invite, user:)
    with_open_invite(invite) do
      Accounts::MoveUser.call(user:, to: invite.account, role: invite.role)

      invite.update!(accepted_at: Time.current)

      user
    end
  end
end
