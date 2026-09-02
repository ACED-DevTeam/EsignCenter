# frozen_string_literal: true

# Account lifecycle states and what they refuse. Session sign-in for an
# archived account already fails through User#active_for_authentication?;
# this module is the request-time guard for everything authenticated by a
# token instead (API keys, MCP tokens, signing sessions).
module AccountStates
  # Timestamp columns that, when set, make every token of the account refuse.
  # Extension point: Session 7 adds :suspended_at here (billing suspension)
  # and nothing else has to change.
  TOKEN_REFUSAL_STATES = %i[archived_at].freeze

  module_function

  # A testing child is the same tenant as its parent: archiving the parent
  # refuses the child's tokens too (the self + testing-parent chain is
  # Account#configuration_lookup_accounts, the Session 1 inheritance helper).
  def tokens_allowed?(account)
    return false if account.nil?

    account.configuration_lookup_accounts.all? { |candidate| active?(candidate) }
  end

  def active?(account)
    TOKEN_REFUSAL_STATES.none? { |state| account.public_send(state).present? }
  end
end
