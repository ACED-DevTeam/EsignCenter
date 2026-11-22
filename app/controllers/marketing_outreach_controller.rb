# frozen_string_literal: true

# POST /api/marketing/outreach — where the Mac automations report each day's
# outreach totals for the marketing page at /admin (docs/marketing-admin.md).
#
# A machine endpoint: no session, no cookie, no CSRF token. The caller proves
# itself with `Authorization: Bearer <MARKETING_OUTREACH_TOKEN>`. Until that
# variable is set the endpoint does not exist (404), so an instance that has
# not been set up cannot be written to by anybody.
class MarketingOutreachController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  def create
    return head :not_found unless MarketingAdmin::Outreach.configured?
    return render json: { error: 'Missing or wrong token' }, status: :unauthorized unless authorized?

    payload = JSON.parse(request.raw_post.presence || '{}')

    return malformed unless payload.is_a?(Hash)

    render json: MarketingAdmin::Outreach.record!(payload)
  rescue JSON::ParserError, ActionDispatch::Http::Parameters::ParseError
    malformed
  rescue MarketingAdmin::Outreach::Invalid => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  private

  def authorized?
    authenticate_with_http_token { |token, _| MarketingAdmin::Outreach.authorized?(token) } == true
  end

  def malformed
    render json: { error: 'Send a JSON object' }, status: :bad_request
  end
end
