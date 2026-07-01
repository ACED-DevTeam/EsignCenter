# frozen_string_literal: true

class EmbedTemplateBuilderController < ApplicationController
  include ActionController::Live

  layout 'plain'

  skip_before_action :authenticate_user!
  skip_authorization_check
  skip_forgery_protection

  before_action :load_template
  before_action :validate_template_param!, except: :show
  before_action :validate_builder_session!
  before_action :validate_request_origin!, except: :show
  before_action :set_embed_frame_headers

  def show
    @template_data = Templates.serialize_for_builder(@template)
    @embed_builder_origin = @builder_preferences['origin']
    @builder_token = params[:token]
  end

  def update_template
    @template.assign_attributes(template_params)
    @template.save!

    SearchEntries.enqueue_reindex(@template)
    WebhookUrls.enqueue_events(@template, 'template.updated')

    render json: @template.as_json(only: %i[id updated_at])
  end

  def documents
    render json: @template.schema_documents.map { |d| ActiveStorage::Blob.proxy_path(d.blob, expires_at: 5.minutes.from_now.to_i) }
  end

  def create_documents
    if params[:blobs].blank? && params[:files].blank?
      return render json: { error: I18n.t('file_is_missing') }, status: :unprocessable_content
    end

    old_fields_hash = @template.fields.hash

    documents, = Templates::CreateAttachments.call(@template, params, extract_fields: true)

    schema = documents.map do |doc|
      { attachment_uuid: doc.uuid, name: doc.filename.base }
    end

    render json: {
      schema:,
      fields: old_fields_hash == @template.fields.hash ? nil : @template.fields,
      submitters: old_fields_hash == @template.fields.hash ? nil : @template.submitters,
      documents: documents.as_json(
        methods: %i[metadata signed_key],
        include: {
          preview_images: { methods: %i[url metadata filename] }
        }
      )
    }
  rescue Templates::CreateAttachments::PdfEncrypted
    render json: { error: 'PDF encrypted', status: 'pdf_encrypted' }, status: :unprocessable_content
  end

  def detect_fields
    response.headers['Content-Type'] = 'text/event-stream'

    sse = SSE.new(response.stream)

    documents = @template.schema_documents.preload(:blob)
    documents = documents.where(uuid: params[:attachment_uuid]) if params[:attachment_uuid].present?

    page_number = params[:page].presence&.to_i

    documents.each do |document|
      io =
        if document.image?
          StringIO.new(document.preview_images.joins(:blob).find_by(blob: { filename: ['0.png', '0.jpg'] }).download)
        else
          StringIO.new(document.download)
        end

      Templates::DetectFields.call(io, attachment: document, page_number:) do |(attachment_uuid, page, fields)|
        sse.write({ attachment_uuid:, page:, fields: })
      end
    end

    sse.write({ completed: true })
  ensure
    response.stream.close
  end

  private

  def load_template
    @template = Template.find_signed!(params[:token], purpose: :embed_builder)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    raise ActionController::RoutingError, I18n.t('not_found')
  end

  def validate_template_param!
    return if @template.id == params[:template_id].to_i

    raise ActionController::RoutingError, I18n.t('not_found')
  end

  def validate_builder_session!
    @builder_preferences = @template.preferences['embed_builder'] || {}

    expires_at = Time.zone.parse(@builder_preferences['expires_at'].to_s) if @builder_preferences['expires_at'].present?

    raise ActionController::RoutingError, I18n.t('not_found') if @builder_preferences['origin'].blank?
    raise ActionController::RoutingError, I18n.t('not_found') if expires_at&.past?
  end

  def validate_request_origin!
    origin = request.headers['Origin'].presence

    return if origin.blank?
    return if origin == request.base_url
    return if origin == @builder_preferences['origin']

    render json: { error: 'Invalid embed origin' }, status: :forbidden
  end

  def set_embed_frame_headers
    response.headers.delete('X-Frame-Options')
    request.content_security_policy&.frame_ancestors(:self, @builder_preferences['origin'])
  end

  def template_params
    params.require(:template).permit(
      :name,
      { schema: [[:attachment_uuid, :google_drive_file_id, :name, :dynamic,
                  { conditions: [%i[field_uuid value action operation]] }]],
        submitters: [%i[name uuid is_requester linked_to_uuid invite_via_field_uuid
                        invite_by_uuid optional_invite_by_uuid email order]],
        variables_schema: {},
        fields: [[:uuid, :submitter_uuid, :name, :type,
                  :required, :readonly, :default_value,
                  :title, :description, :prefillable,
                  { preferences: {},
                    default_value: [],
                    conditions: [%i[field_uuid value action operation]],
                    options: [%i[value uuid]],
                    validation: %i[message pattern min max step],
                    areas: [%i[uuid x y w h cell_w attachment_uuid option_uuid page]] }]] }
    )
  end
end
