# frozen_string_literal: true

# A provider endpoint: no browser session, CSRF, or current_user.
class PostmarkWebhooksController < ActionController::API
  include ActionController::HttpAuthentication::Basic::ControllerMethods

  rescue_from ActionDispatch::Http::Parameters::ParseError, with: :malformed_json

  def create
    unless PostmarkWebhooks.configured?
      Rails.logger.error('Postmark webhook rejected: credentials are not configured')

      return render json: { error: 'Postmark webhook is not configured' }, status: :service_unavailable
    end

    return head :unauthorized unless authenticated?
    return head :forbidden unless PostmarkWebhooks.allowed_ip?(request.remote_ip)
    return head :unsupported_media_type unless request.media_type == 'application/json'

    record = JSON.parse(request.raw_post)

    return malformed_json unless record.is_a?(Hash)

    render json: PostmarkWebhooks.record!(record)
  rescue JSON::ParserError
    malformed_json
  rescue StandardError => e
    ErrorReport.error(e)

    render json: { error: 'Postmark webhook processing failed' }, status: :internal_server_error
  end

  private

  def authenticated?
    authenticate_with_http_basic do |username, password|
      PostmarkWebhooks.authenticated?(username, password)
    end
  end

  def malformed_json
    render json: { error: 'Malformed JSON' }, status: :bad_request
  end
end
