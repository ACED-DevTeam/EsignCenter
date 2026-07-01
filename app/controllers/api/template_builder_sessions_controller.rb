# frozen_string_literal: true

module Api
  class TemplateBuilderSessionsController < ApiBaseController
    CREATE_RATE_LIMIT = 300
    CREATE_RATE_TTL = 1.minute

    before_action :load_template_builder_session, only: :show

    def show
      render json: TemplateBuilderSessions::SerializeForApi.call(@template_builder_session)
    end

    def create
      Params::TemplateBuilderSessionCreateValidator.call(params)

      authorize!(:create, Template.new(account_id: current_account.id, author: current_user))

      RateLimit.call("api-create-template-builder-session-#{current_account.id}",
                     limit: CREATE_RATE_LIMIT, ttl: CREATE_RATE_TTL, enabled: true)

      template = TemplateBuilderSessions::Create.call(user: current_user, ability: current_ability,
                                                      attrs: template_builder_session_params)

      render json: TemplateBuilderSessions::SerializeForApi.call(template)
    rescue Templates::CreateAttachments::PdfEncrypted
      render json: { error: 'The PDF is password-protected. Upload an unencrypted PDF.' },
             status: :unprocessable_content
    rescue Templates::CreateAttachments::InvalidFileType
      render json: { error: 'Unsupported document format. Only PDF and image files are supported.' },
             status: :unprocessable_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Template not found' }, status: :unprocessable_content
    rescue DownloadUtils::UnableToDownload => e
      Rollbar.warning(e) if defined?(Rollbar)

      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def load_template_builder_session
      @template_builder_session = Template.accessible_by(current_ability, :read).find(params[:id])

      authorize!(:update, @template_builder_session)
      validate_builder_session_preferences!
    end

    def template_builder_session_params
      permitted_params = [
        :name, :external_id, :application_key, :folder_name, :template_id, :clone_template_id, :embed_origin,
        :expires_in_minutes,
        {
          metadata: {},
          documents: [%i[name file]],
          submitters: [%i[name role]],
          fields: [[:uuid, :name, :type, :role, :required, :readonly, :title, :description, :default_value,
                    { preferences: {},
                      default_value: [],
                      options: [%i[value]],
                      areas: [%i[x y w h cell_w page document option]] }]]
        }
      ]

      params.permit(permitted_params)
    end

    def validate_builder_session_preferences!
      preferences = @template_builder_session.preferences['embed_builder'] || {}
      expires_at = Time.zone.parse(preferences['expires_at'].to_s) if preferences['expires_at'].present?

      return if preferences['origin'].present? && expires_at&.future?

      render json: { error: 'Template builder session not found' }, status: :not_found
    end
  end
end
