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

      invite = account.account_invites.new(
        email:, role:, invited_by:,
        collision_user: collision_user_for(email, account),
        expires_at: BillingLifecycle::INVITE_TOKEN_DAYS.days.from_now
      )

      invite.generate_token
      invite.save!

      invite
    end
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
  # one fewer — D43, no mid-cycle refunds).
  def revoke!(invite)
    invite.update!(revoked_at: Time.current, released_at: Time.current)

    release_seat_for(invite.account)

    invite
  end

  # Somebody left, or lost their seat: tell Stripe the account needs fewer.
  # Safe to call for any account — it does nothing unless there is a live
  # subscription billing for more seats than are occupied.
  def release_seat_for(account)
    row = Plans.billing_account(account).account_subscription

    BillingLifecycle.release_seats!(row) if row
  end

  # A fresh invitation accepted: the person is created here, in the account
  # that invited them, with the role the invitation carried. The pending
  # invite's seat becomes their seat, so occupancy does not move.
  def accept!(invite, first_name:, last_name:, password:)
    ApplicationRecord.transaction do
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
    Accounts::MoveUser.call(user:, to: invite.account, role: invite.role)

    invite.update!(accepted_at: Time.current)

    user
  end
end
