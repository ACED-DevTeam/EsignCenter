# frozen_string_literal: true

# Account lifecycle states and what they refuse. Session sign-in for an
# archived account already fails through User#active_for_authentication?;
# this module is the request-time guard for everything authenticated by a
# token instead (API keys, MCP tokens, signing sessions, embed
# template-builder tokens).
#
# Two states, and they mean different things:
#   archived  — the account is gone. Nothing works, signer writes included.
#   suspended — the account is frozen for writes only. Everyone can still sign
#               in, read, download and export; signers with a document already
#               in flight still finish it; only creating and changing stops.
module AccountStates
  # Timestamp columns that, when set, make every token of the account refuse.
  # A token is a machine door with no page to explain itself on, so a
  # suspended account's API/MCP/embed/signing-session tokens are refused
  # outright — the human doors stay open and read-only instead.
  TOKEN_REFUSAL_STATES = %i[archived_at suspended_at].freeze

  # Who owns a suspension, and therefore who may lift it. Only 'billing' is
  # written by this phase: 'operator' is the operator console's (Session 8)
  # and 'deletion' belongs to scheduled account deletion (Phase C). Lifting
  # always names the reason it expects, so a payment going through can never
  # undo an operator's or a deletion's suspension.
  SUSPENSION_REASONS = %w[billing operator deletion].freeze

  BILLING_REASON = 'billing'

  # Raised when TOKEN_REFUSAL_STATES names something the accounts table does
  # not have — a column renamed or a state added without its migration. The
  # alternative is a NoMethodError from deep inside a token guard, which
  # reads like a bug in the door rather than in this list.
  class MissingStateColumn < StandardError; end

  module_function

  # A testing child is the same tenant as its parent: archiving (or
  # suspending) the parent refuses the child's tokens too (the self +
  # testing-parent chain is Account#configuration_lookup_accounts, the
  # Session 1 inheritance helper).
  def tokens_allowed?(account)
    return false if account.nil?

    account.configuration_lookup_accounts.all? { |candidate| active?(candidate) }
  end

  def active?(account)
    TOKEN_REFUSAL_STATES.none? do |state|
      unless account.respond_to?(state)
        raise MissingStateColumn, "AccountStates::TOKEN_REFUSAL_STATES names #{state}, which is not a column " \
                                  'on accounts — add the migration, or take the state out of the list'
      end

      account.public_send(state).present?
    end
  end

  # Is every write on this account refused right now? True when the account
  # itself is suspended, when the account that PAYS for it is (a linked child
  # loses writing when its parent stops paying), or when its testing parent
  # is — the same tenant chain the token guard walks.
  def read_only?(account)
    return false if account.nil?

    suspension_candidates(account).any? { |candidate| candidate.suspended_at.present? }
  end

  # Self, the testing parent (if any) and the billing account: the three
  # accounts whose suspension freezes this one.
  def suspension_candidates(account)
    ([account] + account.configuration_lookup_accounts + [Plans.billing_account(account)]).compact.uniq(&:id)
  end

  # Idempotent, and under the account's row lock so two workers (a webhook
  # and the hourly dunning sweep) cannot both decide they were the one that
  # suspended it. Returns true only from the call that actually changed the
  # state, so the caller knows whether to send the mail.
  #
  # Internal and operator accounts are the platform itself and are exempt
  # from every billing rule — they are never suspended, whoever asks.
  def suspend!(account, reason:)
    return false if account.nil? || !account.customer?

    assert_known_reason!(reason)

    changed = account.with_lock do
      next false if account.suspended_at.present?

      account.update!(suspended_at: Time.current, suspension_reason: reason.to_s)

      true
    end

    ErrorReport.info("account suspended (#{reason})", account_id: account.id) if changed

    changed
  end

  # A reason nobody owns could never be lifted, so it is a programming error
  # rather than a state to store.
  def assert_known_reason!(reason)
    return if SUSPENSION_REASONS.include?(reason.to_s)

    raise ArgumentError, "unknown suspension reason #{reason.inspect}"
  end

  # Lifts ONLY a suspension this caller owns: a payment going through clears
  # a 'billing' suspension and leaves an operator's or a deletion's exactly
  # where it is. Idempotent; true only when it changed something.
  def lift_suspension!(account, reason:)
    return false if account.nil?

    changed = account.with_lock do
      next false if account.suspended_at.blank?
      next false if account.suspension_reason.to_s != reason.to_s

      account.update!(suspended_at: nil, suspension_reason: nil)

      true
    end

    ErrorReport.info("account suspension lifted (#{reason})", account_id: account.id) if changed

    changed
  end
end
