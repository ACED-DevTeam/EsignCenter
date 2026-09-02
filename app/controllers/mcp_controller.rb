# frozen_string_literal: true

class McpController < ActionController::API
  include TokenAccountGuard

  before_action :authenticate_user!
  before_action :require_mcp_entitlement!
  before_action :verify_mcp_enabled!

  before_action do
    authorize!(:manage, :mcp)
  end

  def call
    return head :ok if request.raw_post.blank?

    body = JSON.parse(request.raw_post)

    result = Mcp::HandleRequest.call(body, current_user, current_ability)

    if result
      render json: result
    else
      head :accepted
    end
  rescue CanCan::AccessDenied
    render json: { jsonrpc: '2.0', id: nil, error: { code: -32_603, message: 'Forbidden' } }, status: :forbidden
  rescue JSON::ParserError
    render json: { jsonrpc: '2.0', id: nil, error: { code: -32_700, message: 'Parse error' } }, status: :bad_request
  end

  private

  def authenticate_user!
    return render json: { error: 'Not authenticated' }, status: :unauthorized unless current_user

    refuse_inactive_token_account!
  end

  # This door authenticates by bearer token only, so the current user is
  # always the token's user.
  def token_account_user
    current_user
  end

  # MCP is a paid-only row: `:manage, :mcp` says the role may administer MCP,
  # `:use, :mcp` says the account's plan includes it (Ability#plan_abilities).
  def require_mcp_entitlement!
    return if current_ability.can?(:use, :mcp)

    render json: { error: Entitlements::REFUSAL_MESSAGE }, status: :forbidden
  end

  # The account's enable-MCP toggle governs, for every plan.
  def verify_mcp_enabled!
    return if AccountConfig.exists?(account_id: current_user.account_id,
                                    key: AccountConfig::ENABLE_MCP_KEY,
                                    value: true)

    render json: { error: 'MCP is disabled' }, status: :forbidden
  end

  def current_user
    @current_user ||= user_from_api_key
  end

  def user_from_api_key
    token = request.headers['Authorization'].to_s[/\ABearer\s+(.+)\z/, 1]

    return if token.blank?

    sha256 = Digest::SHA256.hexdigest(token)

    User.joins(:mcp_tokens).active.find_by(mcp_tokens: { sha256:, archived_at: nil })
  end
end
