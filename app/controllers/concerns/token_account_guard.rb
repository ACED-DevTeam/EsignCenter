# frozen_string_literal: true

# The one token-door refusal. A request that presents a token belonging to an
# account that has left the active state is refused, and the refusal never says
# why. Anonymous requests and unknown tokens pass through untouched — the
# door's own authentication answers those.
module TokenAccountGuard
  extend ActiveSupport::Concern

  private

  # The user the presented token resolves to, or nil when none does. Every
  # door names its own token lookup.
  def token_account_user
    raise NotImplementedError
  end

  def refuse_inactive_token_account!
    user = token_account_user

    return if user.nil? || AccountStates.tokens_allowed?(user.account)

    render json: { error: 'Account is not active' }, status: :unauthorized
  end
end
