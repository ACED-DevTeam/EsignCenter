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

  # The invited address belongs to a login that has been closed (an archived
  # user in another account). Nobody can ever sign in as it, so an invitation
  # to it is a seat held for a link that can never be used — and on a paid
  # account it would be a seat BOUGHT for one. Refused before any money moves.
  # A kind of AlreadyInvited so every door that already answers that refusal
  # with a sentence answers this one the same way.
  class AddressUnavailable < AlreadyInvited; end

  # The invitation cannot be acted on any more: somebody cancelled it, it
  # lapsed, the team it points at is frozen, or the seat it was holding is no
  # longer there. Carries the sentence the acceptance page shows.
  class NoLongerOpen < StandardError; end

  # The person pressing the button is not the person the invitation names.
  # Asked again inside the row lock, because who holds the invited address
  # can change between the page and the click. Carries the sentence the page
  # shows — never a validation error, never a 500.
  class WrongInvitee < StandardError; end

  module_function

  def normalize_email(email)
    email.to_s.strip.downcase
  end

  # The user this address already belongs to somewhere else, or nil. Email is
  # unique across the whole app, so there is at most one — and if they are in
  # THIS account it is not a collision, it is an ordinary duplicate.
  #
  # `.active` because an archived login can never sign in: an invitation whose
  # only accept path is "sign in as that person" would be dead on arrival
  # (review B3). Those are refused outright in `assert_invitable!` below.
  #
  # What comes back is a HINT, stored on the row so the invitation email can
  # name the account somebody is being asked to leave. It authorizes nothing:
  # every decision at accept time is re-asked from the invited ADDRESS, in
  # `verdict_for`, because the world moves between the invitation and the
  # click (review B1/B2).
  def collision_user_for(email, account)
    user = User.active.find_by(email: normalize_email(email))

    return nil if user.nil? || user.account_id == account.id

    user
  end

  # Whoever holds an ADDRESS right now, archived or not. Email is unique
  # across the whole app, so there is at most one. Every question of the shape
  # "who has this address?" — the collision hint, the accept-time verdict, the
  # closed-login refusal — asks it here, so they can never disagree.
  def holder_of(email)
    User.find_by(email: normalize_email(email))
  end

  # The same question about the address an invitation names.
  def holder_for(invite)
    holder_of(invite.email)
  end

  # What this invitation means AT THIS MOMENT, asked from the address rather
  # than from anything stored when it was written. Four answers:
  #
  #   :fresh        — nobody holds the address: the sign-up form, as always.
  #   :move         — somebody else's active login holds it: the "join this
  #                   team" offer (D50).
  #   :member       — they are already in the inviting account: nothing to
  #                   accept, and the seat the invitation still holds goes back.
  #   :closed_login — an archived login holds it: nobody can sign in as it and
  #                   creating a second user with it would hit the unique
  #                   email index, so the link says so in a sentence.
  #
  # This is the whole of review B1: collision used to be decided once, when
  # the invitation was written, and never asked again — so "admin invites,
  # colleague signs themselves up, colleague clicks the link" fell down the
  # fresh path and died on the unique email index with "Email has already
  # been taken", holding (on a paid account, having bought) a seat for a week.
  def verdict_for(invite)
    holder = holder_for(invite)

    return :fresh if holder.nil?
    return :closed_login if holder.archived_at.present?
    return :member if holder.account_id == invite.account_id
    return :closed_login if closed_account?(holder.account)

    :move
  end

  # The other half of "nobody can ever sign in as this address" (review 7,
  # Q-3). The user row is untouched, but their ACCOUNT has been archived or
  # its purge has been claimed, and `User#active_for_authentication?` refuses
  # everybody in such an account. The move this invitation offers could
  # therefore never be accepted, and on a paid account the seat it holds was
  # BOUGHT — so it is answered with the closed-login sentence now rather than
  # sitting there until it lapses.
  def closed_account?(account)
    account.present? && (account.archived_at.present? || account.purge_claimed?)
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

  # --- parked purchases (checkpoint 7, B1) -----------------------------------
  #
  # Stripe answered the seat purchase with a `pending_update`: the card needs a
  # second step, nothing has been charged and the subscription still bills the
  # old number. The invitation is written anyway, PARKED — it holds no seat,
  # nobody is mailed, and it cannot be accepted — purely so that the purchase
  # the customer is about to finish in Stripe's own portal ends where it was
  # always meant to end: with the invitation they paid for.
  #
  # Three ways out, and no fourth:
  #   * the subscription later applies with at least the quantity that was
  #     bought → `promote_parked!` turns the row into an ordinary pending
  #     invitation and sends the mail;
  #   * Stripe's pending update expires first → `discard_parked!` drops the row
  #     on the hourly sweep, asking Stripe for nothing (nothing was added);
  #   * an admin cancels it from the users page like any other invitation.

  # Write the parked row. `expires_at` is Stripe's own deadline for the pending
  # update, so an admin looking at the database sees one clock rather than two;
  # the real 7-day invitation week starts when the seat is actually paid for.
  def park!(invite, quantity:, expires_at:)
    invite.assign_attributes(payment_pending_until: expires_at, pending_quantity: quantity,
                             expires_at:)
    invite.save!

    invite
  end

  # A subscription just applied with `quantity` seats. Which parked purchases
  # did that quantity actually pay for?
  #
  # Not "every parked row the new quantity is big enough for" — that was
  # checkpoint 7's P3. Two colleagues invited while one card needed a second
  # step leave two parked rows, both bought at quantity 2; the customer
  # finishes ONE of them, Stripe bills for 2, and promoting both would mail
  # two people an invitation for one seat and leave the account occupying 3
  # seats on a subscription that bills 2. The second person would then be
  # refused at the accept button, having been told they were invited.
  #
  # So the number promoted is the number of seats the applied quantity has
  # room for — `quantity` minus what the account occupies right now (people
  # plus the invitations already holding seats; a parked row holds none) —
  # taken oldest first, and never more than that however many are waiting.
  # A row parked for a quantity HIGHER than the one that applied was not paid
  # for at all and is left where it is; it lapses with Stripe's own deadline
  # and `discard_parked!` drops it. A row whose OWN deadline has already
  # passed is skipped for the same reason (checkpoint 7, V2): Stripe gave up
  # on that pending update, so the purchase never happened — whether or not
  # the hourly sweep has got round to settling the row yet.
  #
  # What spends a seat here is a PROMOTION, not a delivered email (checkpoint
  # 7, V1). Once the row is a live pending invitation it occupies its seat
  # whatever the mail server did; a delivery that failed is reported and
  # retried from the Resend button, never by promoting somebody else into the
  # same seat.
  #
  # Under the billing account's creation lock, the same lock every other seat
  # decision is taken inside (`reserve!`, the free-seat fill), so the
  # occupancy this reads cannot go stale between the count and the promotion.
  def promote_parked!(billing_account, quantity:)
    quantity = quantity.to_i
    account_ids = Accounts.seat_account_ids(billing_account)

    Quotas.with_creation_lock(billing_account) do
      parked = AccountInvite.payment_pending
                            .where(account_id: account_ids)
                            .where(payment_pending_until: Time.current..)
                            .where(pending_quantity: ..quantity)
                            .order(:created_at, :id)
                            .to_a

      seats_to_fill = quantity - Accounts.seat_occupancy(billing_account)

      parked.each do |invite|
        break if seats_to_fill <= 0

        seats_to_fill -= 1 if promote!(invite).present?
      end
    end

    nil
  end

  # One parked row becomes a real invitation: a fresh token (the one minted
  # when it was parked was never given to anybody and cannot be recovered), a
  # fresh week, and the mail. Asked again, under the row lock, whether the
  # address is still invitable at all — a week is long enough for the person to
  # have joined by another door, and an invitation that cannot be written is
  # dropped rather than forced.
  #
  # Answers with the invitation when the row was PROMOTED — which is not the
  # same question as "did the email go out" (checkpoint 7, V1). The moment the
  # row is flipped it is a live pending invitation occupying a seat, so a
  # delivery that fails afterwards must still count against the caller's cap;
  # telling the caller "nothing happened" would promote the next parked row
  # into the very same seat and put the account back at two invitations for
  # one paid-for seat. nil means the row is still parked (or was dropped).
  def promote!(invite)
    raw_token = nil

    return nil unless claim_parked_seat!(invite) { |token| raw_token = token }

    deliver_promotion!(invite, raw_token)

    invite
  end

  # The flip itself, under the row's own lock: a fresh token, a fresh week,
  # and the parked columns cleared. Anything that goes wrong in here leaves
  # the row parked (the lock's transaction rolls back), so it is reported and
  # answered with false — no seat spent.
  def claim_parked_seat!(invite)
    invite.with_lock do
      next false unless invite.payment_pending?
      next false unless invitable_now?(invite)

      yield invite.generate_token
      invite.update!(payment_pending_until: nil, pending_quantity: nil,
                     expires_at: BillingLifecycle::INVITE_TOKEN_DAYS.days.from_now)

      true
    end
  rescue StandardError => e
    ErrorReport.error(e, account_id: invite.account_id)

    false
  end

  # The row is already a live invitation by the time this runs, so a delivery
  # that fails is not "nothing happened": it is a pending invitation nobody
  # has heard about, listed on Settings → Users with a Resend button next to
  # it. Reported once, never raised — the caller is a webhook — and the seat
  # stays spent.
  def deliver_promotion!(invite, raw_token)
    deliver!(invite, raw_token)
  rescue StandardError => e
    ErrorReport.error(e, account_id: invite.account_id)

    nil
  end

  # Is the parked address still one this account may invite? Refusals here are
  # the ordinary ones (they joined in the meantime, somebody invited them
  # again, their login closed), and every one of them means the parked row has
  # to go rather than become a second invitation to the same person. The seat
  # the customer paid for is not lost: it is simply unoccupied, and the hourly
  # seat sweep hands it back.
  #
  # `AddressUnavailable` is spelled out alongside its parent on purpose
  # (checkpoint 7, P6): a parked address whose login was closed somewhere else
  # in the meantime is an ORDINARY refusal like the other two — the row goes,
  # the seat is handed back by the sweep — and it must never fall through to
  # `promote!`'s last-resort rescue, which would file an error report on every
  # subsequent apply until Stripe's deadline expired. It is a subclass today,
  # so the list is documentation; if it ever stops being one, this line is
  # what keeps the behaviour.
  def invitable_now?(invite)
    assert_invitable!(invite.account, invite.email)

    true
  rescue AddressUnavailable, AlreadyInvited, InvalidEmail
    invite.update!(released_at: Time.current)

    false
  end

  # The hourly sweep's half: Stripe gave up on the pending update, so the
  # purchase never happened. Nothing was ever added to the subscription, so
  # this asks Stripe for nothing at all — the row is simply marked settled so
  # it stops being a parked purchase and stops being shown to anybody.
  def discard_parked!(now: Time.current)
    AccountInvite.payment_pending
                 .where(payment_pending_until: ..now)
                 .update_all(released_at: now, updated_at: now)
  end

  # An address already in the account (or already invited), or one that is not
  # an address at all, is a mistake worth a sentence, not a seat. An address in
  # ANOTHER account is not: that is the "join this team" offer and it goes
  # through exactly like a fresh one.
  def assert_invitable!(account, email)
    assert_email_shape!(email)

    raise AlreadyInvited, I18n.t('already_exists') if User.where(account_id: account.id).active.exists?(email:)

    raise AlreadyInvited, I18n.t('invite_already_pending') if pending_for(account, email)

    raise AddressUnavailable, I18n.t('invite_address_closed_admin') if closed_login_elsewhere?(account, email)
  end

  # An archived login in ANOTHER account. Their address is spoken for — the
  # unique email index will not let a second user have it — and they cannot
  # sign in to accept a move, so no invitation to it can ever be used. An
  # archived colleague of THIS account is a different story and never reaches
  # here: UsersController brings them back instead (its reactivate branch).
  def closed_login_elsewhere?(account, email)
    holder = holder_of(email)

    holder.present? && holder.archived_at.present? && holder.account_id != account.id
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
  #
  # `deliver_now!` rather than `deliver_later!`, and that is the whole of
  # review 7's D50 D4.
  #
  # This token IS the invitation: whoever holds it can create a confirmed user
  # in the inviting account with a password of their own choosing (`accept!`
  # below). Enqueueing the mail put that token, in plain text, into a Sidekiq
  # job's arguments — and a Sidekiq payload is not a transient thing. It sits
  # in Redis while the job waits, again on every one of its retries, and
  # indefinitely in the dead set if delivery keeps failing; the whole of it is
  # printed on the operator's Sidekiq Web UI, which this app mounts in
  # production (config/routes.rb). The row itself only ever holds the token's
  # DIGEST, precisely so that a database read cannot rebuild an accept link —
  # and the queue was quietly undoing that.
  #
  # Delivering inline keeps the token in one process's memory for the length
  # of one request and writes it nowhere. The promise the callers depend on is
  # unchanged: `deliver_now!` raises on a delivery that fails, exactly as
  # `deliver_later!` did inside its job, so a failure is still surfaced rather
  # than swallowed. What changes is WHERE it surfaces — in the request that
  # asked for it rather than in a retrying worker — and that is the honest
  # place for it: an invitation whose mail never left is not an invitation.
  def deliver!(invite, raw_token = invite.raw_token)
    AccountInviteMailer.invitation(invite, raw_token).deliver_now!
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
    # A parked purchase is cancelled by a different rule (checkpoint 7, P5):
    # it holds no seat and nothing was ever added to the subscription, so
    # there is nothing to hand back and Stripe is asked for nothing at all.
    # `parked?` rather than `payment_pending?` on purpose (checkpoint 7, V2):
    # a row whose Stripe deadline passed an hour before the sweep runs is
    # still a parked purchase, and cancelling it has to settle it truthfully
    # rather than report success and change nothing.
    return revoke_parked!(invite) if parked?(invite)

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

  # An admin cancelled a parked purchase from the users page. The customer has
  # decided not to finish the card step, so the row is settled here and now —
  # `released_at` as well as `revoked_at`, because "handled with Stripe" is
  # true the moment it is written: the quantity never moved, so there is
  # nothing to ask Stripe to take back and nothing for the hourly sweep to
  # retry. If the customer finishes the step anyway, the row is no longer
  # parked and cannot be promoted; the seat that arrives with nobody in it is
  # handed back by the ordinary reconciliation.
  def revoke_parked!(invite)
    invite.with_lock do
      next unless parked?(invite)

      invite.update!(revoked_at: Time.current, released_at: Time.current)
    end

    invite
  end

  # Is this row a parked purchase at all — settled by nobody, accepted by
  # nobody, cancelled by nobody? The same question the `payment_pending`
  # SCOPE asks, and deliberately WITHOUT the deadline the `payment_pending?`
  # predicate adds (checkpoint 7, V2). Stripe's deadline decides whether the
  # purchase can still be finished; it does not decide whether the row is a
  # parked purchase. Between the deadline passing and the hourly
  # `discard_parked!` sweep the row is an EXPIRED parked purchase: it was
  # never a pending invitation, so it must never be shown as one, resent, or
  # promoted — but it is still the thing Cancel has to settle.
  def parked?(invite)
    invite.payment_pending_until.present? && invite.accepted_at.nil? &&
      invite.revoked_at.nil? && invite.released_at.nil?
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
  #
  # This is the third door in the product that creates a login, so it is the
  # third that records an agreement to the Terms and the Privacy Policy — in
  # the invitation's own lock, alongside the user row, so the two can only
  # exist together. `request` is what stamps the IP and browser on that
  # record; it is optional because not every caller is a browser. `versions`
  # is what the acceptance page said it was showing: a mismatch raises
  # LegalDocuments::StaleVersionError and nothing at all is created, because a
  # week-old invitation link can outlive a wording change.
  #
  # A MOVE (accept_move! below) records nothing: that person already has a
  # login and already agreed when they made it.
  def accept!(invite, first_name:, last_name:, password:, request: nil, versions: nil)
    with_open_invite(invite) do
      assert_address_free!(invite)

      user = invite.account.users.new(email: invite.email, first_name:, last_name:,
                                      role: invite.role, password:)
      user.skip_confirmation!
      user.save!

      LegalDocuments.record_acceptance!(user, request:, source: LegalAcceptance::INVITE, versions:)

      invite.update!(accepted_at: Time.current)

      user
    end
  end

  # The collision case (D50): the invitee already has an account of their own
  # and accepts by MOVING into the team, bringing everything with them.
  def accept_move!(invite, user:)
    with_open_invite(invite) do
      # The user row is locked and RE-READ before it is asked who they are
      # (review 7, D50 D2). The invitation's own lock serialises two clicks on
      # THIS invitation; it says nothing at all about a second invitation, from
      # a different team, being accepted by the same person at the same moment
      # — that one holds a different row. The user row is the thing both
      # acceptances have in common, so it is the thing that has to be locked,
      # and locking it here means the address this invitation is checked
      # against is the address the database holds now rather than the one the
      # page was drawn with. Accounts::MoveUser takes the same lock again
      # inside; a lock already held in this transaction costs nothing to
      # re-take, and re-reading under it is exactly what the second acceptance
      # needs.
      #
      # `from` is read BEFORE the lock on purpose: it is the account this
      # acceptance was offered and authorized against — the one the invitee was
      # shown on the join screen — and handing it to the move is what lets the
      # move refuse a person who has since been moved somewhere else entirely.
      from = user.account

      user.lock!

      assert_invitee!(invite, user)

      Accounts::MoveUser.call(user:, from:, to: invite.account, role: invite.role)

      invite.update!(accepted_at: Time.current)

      user
    end
  end

  # Nobody may take a seat on an invitation addressed to somebody else. The
  # comparison is on the ADDRESS, not on a stored user id: the id was written
  # when the invitation was, and the person behind it can change their own
  # email afterwards — which used to move a different address, and everything
  # in its account, into the team (review B2).
  def assert_invitee!(invite, user)
    return true if normalize_email(user.email) == normalize_email(invite.email)

    raise WrongInvitee, I18n.t('invite_sign_in_as_other_user', email: invite.email)
  end

  # The fresh path creates a login, so the address has to still be free when
  # the row is written — inside the same lock, because somebody can sign
  # themselves up in the seconds between the page and the button. Answering
  # with a sentence is the whole point: the unique email index answers with
  # "Email has already been taken", which leaves the invitee nowhere to go.
  def assert_address_free!(invite)
    holder = holder_for(invite)

    return true if holder.nil?
    raise WrongInvitee, I18n.t('invite_address_closed_login') if holder.archived_at.present?

    raise WrongInvitee, I18n.t('invite_address_now_registered', email: invite.email)
  end
end
