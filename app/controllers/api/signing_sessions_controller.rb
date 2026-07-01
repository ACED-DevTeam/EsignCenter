# frozen_string_literal: true

module Api
  class SigningSessionsController < ApiBaseController
    # Match the existing template-create API backstop because this endpoint can
    # create a template and submission in one call.
    CREATE_RATE_LIMIT = 300
    CREATE_RATE_TTL = 1.minute

    before_action :load_signing_session, only: :show

    def show
      render json: SigningSessions::SerializeForApi.call(@signing_session, params:)
    end

    def create
      Params::SigningSessionCreateValidator.call(params)

      authorize!(:create, Template.new(account_id: current_account.id, author: current_user))
      authorize!(:create, Submission)

      RateLimit.call("api-create-signing-session-#{current_account.id}",
                     limit: CREATE_RATE_LIMIT, ttl: CREATE_RATE_TTL, enabled: true)

      submission = SigningSessions::Create.call(user: current_user, ability: current_ability,
                                                attrs: signing_session_params)

      render json: SigningSessions::SerializeForApi.call(submission)
    rescue Templates::CreateAttachments::PdfEncrypted
      render json: { error: 'The PDF is password-protected. Upload an unencrypted PDF.' },
             status: :unprocessable_content
    rescue Templates::CreateAttachments::InvalidFileType
      render json: { error: 'Unsupported document format. Only PDF and image files are supported.' },
             status: :unprocessable_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Template not found' }, status: :unprocessable_content
    rescue Submitters::NormalizeValues::BaseError, Submissions::CreateFromSubmitters::BaseError,
           DownloadUtils::UnableToDownload => e
      Rollbar.warning(e) if defined?(Rollbar)

      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def load_signing_session
      @signing_session = current_account.submissions.where(source: :embed).find(params[:id])

      authorize!(:read, @signing_session)
    end

    def signing_session_params
      permitted_params = [
        :name, :external_id, :application_key, :folder_name, :template_id, :embed_origin,
        :completed_redirect_url, :send_email, :send_sms, :reply_to, :bcc_completed,
        :expire_at, :order, :submitters_order,
        {
          embed_origins: [],
          metadata: {},
          variables: {},
          message: %i[subject body],
          documents: [%i[name file]],
          submitters: [[:send_email, :send_sms, :completed_redirect_url, :uuid, :name, :email, :role,
                        :completed, :phone, :application_key, :external_id, :reply_to, :go_to_last,
                        :require_phone_2fa, :require_email_2fa, :order, :index, :invite_by,
                        { metadata: {}, values: {}, roles: [], readonly_fields: [], message: %i[subject body],
                          fields: [:name, :uuid, :default_value, :value, :title, :description,
                                   :readonly, :required, :validation_pattern, :invalid_message,
                                   { default_value: [], value: [], preferences: {}, validation: {} }] }]],
          fields: [[:uuid, :name, :type, :role, :required, :readonly, :title, :description, :default_value,
                    { preferences: {},
                      default_value: [],
                      options: [%i[value]],
                      areas: [%i[x y w h cell_w page document option]] }]]
        }
      ]

      params.permit(permitted_params)
    end
  end
end
