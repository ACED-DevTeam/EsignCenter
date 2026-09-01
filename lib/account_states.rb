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

  def tokens_allowed?(account)
    return false if account.nil?

    TOKEN_REFUSAL_STATES.none? { |state| account.public_send(state).present? }
  end
end
