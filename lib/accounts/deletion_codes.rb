# frozen_string_literal: true

module Accounts
  # The second way to prove it is really you before deleting the account
  # (review batch 2, K9 and P5).
  #
  # The first way is your password, and for most people that is the end of it.
  # The branch this replaces asked a Google-only administrator to type the
  # ACCOUNT NAME instead, on the theory that they have no password — and they
  # do: OmniauthCallbacksController creates every Google user with a random
  # `Devise.friendly_token` password, so the "no password" branch could never
  # run and such an administrator could never confirm a deletion at all. The
  # account name was also printed on the screen directly above the field,
  # which made it a typing exercise rather than a proof.
  #
  # So the second way is a code emailed to the administrator's own address:
  # they have to still control the mailbox.
  #
  # The code is STORED, not derived, and that is the whole of P5. A TOTP over
  # the server secret — the shape this replaces — has three faults that only
  # look small: every 15-minute window has a valid code whether or not one was
  # ever emailed; the same code keeps working after it has been used; and the
  # attempt budget lived in Redis, so an unreachable Redis failed OPEN and
  # handed an attacker unlimited guesses at a six-digit number.
  #
  # What is stored instead: a SHA-256 of the code salted with the user's id
  # (the database never holds the code itself), an expiry, the user it was
  # issued to, and the attempt count — in a COLUMN, so nothing about this can
  # fail open. Asking for a new code replaces the old one. A correct code is
  # consumed the moment it is accepted, so it cannot be replayed.
  module DeletionCodes
    # How long a code lasts.
    TTL = 15.minutes

    # Guesses allowed before the code is thrown away. Six digits with five
    # tries is a one-in-two-hundred-thousand chance; without this it is a free
    # oracle.
    MAX_ATTEMPTS = 5

    # And the budget is spent per WINDOW, not per code (review batch 2, R6).
    # Re-issuing used to reset the count to zero, so five guesses could be
    # turned into fifteen simply by pressing "Email me a confirmation code"
    # again — and the only thing in the way was a Redis throttle, which fails
    # open when Redis is unreachable. The count now survives a re-issue and
    # only starts again once this long has passed since the first guess of the
    # window.
    ATTEMPT_WINDOW = 30.minutes

    # How many codes one administrator may ask for, and over what period. A
    # fresh code resets the guess budget, so without this the attempt limit
    # could be lifted simply by asking again.
    MAX_ISSUES = 3
    ISSUE_WINDOW = 15.minutes

    # Raised when the guesses run out, or when codes are being asked for
    # faster than a person asks for them. Named so the controller can say
    # "too many attempts" rather than "wrong code" — which is the truth, and
    # is also what stops somebody quietly grinding away.
    class TooManyAttempts < StandardError; end

    module_function

    # A fresh six-digit code for this administrator. Returns the code, which
    # is the only moment it exists in plain text; the row keeps its digest.
    # Issuing one INVALIDATES any code still outstanding on the account and
    # resets the guess budget, which is why issuing is itself rate-limited.
    def issue!(account, user)
      throttle_issue!(user)

      code = format('%06d', SecureRandom.random_number(1_000_000))

      account.with_lock do
        # The attempt count is carried over unless its window has run out: a
        # fresh code is a fresh CODE, never a fresh budget (R6).
        window = current_window(account)

        account.update!(deletion_code_digest: digest(code, user),
                        deletion_code_expires_at: TTL.from_now,
                        deletion_code_attempts: window ? account.deletion_code_attempts.to_i : 0,
                        deletion_code_window_started_at: window,
                        deletion_code_user_id: user.id)
      end

      code
    end

    # The guessing window this account is in, or nil when there is none open.
    def current_window(account)
      started = account.deletion_code_window_started_at

      started if started.present? && started > ATTEMPT_WINDOW.ago
    end

    # True only for the code this administrator was actually sent, while it is
    # still fresh and while the guess budget lasts. Every call spends one
    # attempt, right or wrong: a correct guess after four wrong ones is still
    # an attack.
    #
    # Everything happens under the account's row lock, so two browser tabs
    # cannot each spend the same attempt, and success CLEARS the code in the
    # same breath — a code that has been accepted once can never be replayed.
    # The exhausted case RETURNS from the lock and raises outside it. Raising
    # from inside `with_lock` rolls its transaction back, which would undo the
    # very thing the last attempt is for — the attempt count and the destroyed
    # code — and hand the attacker their budget back on every sixth guess.
    def verify!(account, user, code)
      digits = code.to_s.gsub(/\D/, '')

      outcome = account.with_lock { attempt(account, user, digits) }

      raise TooManyAttempts if outcome == :exhausted

      outcome == :ok
    end

    # One guess, under the caller's lock. Returns :ok, :wrong, :none or
    # :exhausted; every path that touches the row commits with the block.
    def attempt(account, user, digits)
      return :none unless issued_to?(account, user)

      if expired?(account)
        clear!(account)

        return :none
      end

      window = current_window(account)
      spent = (window ? account.deletion_code_attempts.to_i : 0) + 1

      account.update!(deletion_code_attempts: spent,
                      deletion_code_window_started_at: window || Time.current)

      if spent > MAX_ATTEMPTS
        clear!(account)

        return :exhausted
      end

      return :wrong unless correct?(account, digits, user)

      clear!(account)

      :ok
    end

    # A code that was never issued, or was issued to somebody else, is not a
    # code. (`deletion_code_user_id` matters because two administrators can be
    # in the modal at once and only the one who asked holds the mailbox.)
    def issued_to?(account, user)
      account.deletion_code_digest.present? && account.deletion_code_user_id == user.id
    end

    def expired?(account)
      account.deletion_code_expires_at.blank? || account.deletion_code_expires_at <= Time.current
    end

    def correct?(account, digits, user)
      return false if digits.length != 6

      ActiveSupport::SecurityUtils.secure_compare(account.deletion_code_digest.to_s, digest(digits, user))
    end

    # Clears the CODE. The attempt window is deliberately left alone: it is
    # what stops the budget being refilled by asking for another one, and it
    # expires on its own (R6).
    def clear!(account)
      account.update!(deletion_code_digest: nil, deletion_code_expires_at: nil, deletion_code_user_id: nil)
    end

    # Salted with the user id so one account's stored digest says nothing
    # about another's, and so a digest lifted from a backup cannot be replayed
    # against a different administrator.
    def digest(code, user)
      Digest::SHA256.hexdigest([Rails.application.secret_key_base, 'account_deletion', user.id, code].join(':'))
    end

    # The only part that leans on Redis, and it leans the safe way: this
    # limits how often a code may be ASKED for, so a store that answers
    # nothing lets a person ask again — it can never let anybody guess more
    # (RateLimit.call returns true when the store is unreachable). The
    # guessing budget is the column above, which cannot fail open.
    def throttle_issue!(user)
      RateLimit.call("account-deletion-code-issue-#{user.id}", limit: MAX_ISSUES, ttl: ISSUE_WINDOW)
    rescue RateLimit::LimitApproached
      raise TooManyAttempts
    end
  end
end
