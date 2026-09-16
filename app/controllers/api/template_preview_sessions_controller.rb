# frozen_string_literal: true

module Api
  # Mints a short-lived, read-only preview of a template's signing form so a
  # paired app can show "this is what the signer will see" without creating a
  # submission, a submitter or any other row. Nothing is persisted: the returned
  # URL carries a signed, expiring token and is served by
  # EmbedTemplatePreviewController.
  class TemplatePreviewSessionsController < ApiBaseController
    CREATE_RATE_LIMIT = 300
    CREATE_RATE_TTL = 1.minute

    before_action -> { Entitlements.require!(current_account, :embed) }

    def create
      Params::TemplatePreviewSessionCreateValidator.call(params)

      authorize!(:read, Template.new(account_id: current_account.id, author: current_user))

      RateLimit.call("api-create-template-preview-session-#{current_account.id}",
                     limit: CREATE_RATE_LIMIT, ttl: CREATE_RATE_TTL, enabled: true)

      session = TemplatePreviewSessions::Create.call(user: current_user, ability: current_ability,
                                                     attrs: template_preview_session_params)

      render json: TemplatePreviewSessions::SerializeForApi.call(session)
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Template not found' }, status: :not_found
    end

    private

    def template_preview_session_params
      params.permit(:template_id, :embed_origin, :expires_in_minutes, values: {})
    end
  end
end
