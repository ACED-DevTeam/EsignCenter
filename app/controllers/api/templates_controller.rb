# frozen_string_literal: true

module Api
  class TemplatesController < ApiBaseController
    MAX_DOCUMENTS = 20
    MAX_DOCUMENT_SIZE = 25.megabytes
    MAX_ENCODED_DOCUMENT_SIZE = ((MAX_DOCUMENT_SIZE * 4) / 3) + 1.kilobyte
    # Generous per-account backstop against runaway loops / abuse. The 429 response
    # is rendered by ApiBaseController's rescue_from RateLimit::LimitApproached.
    CREATE_RATE_LIMIT = 300
    CREATE_RATE_TTL = 1.minute

    load_and_authorize_resource :template, except: :create

    before_action only: :create do
      authorize!(:create, Template.new(account_id: current_account.id, author: current_user))
    end

    def index
      templates = filter_templates(@templates, params)

      templates = paginate(templates.preload(:author, folder: :parent_folder))

      schema_documents, dynamic_documents, preview_image_attachments = preload_relations(templates)

      expires_at = Accounts.link_expires_at(current_account)

      render json: {
        data: templates.map do |t|
          Templates::SerializeForApi.call(t,
                                          schema_documents: schema_documents.select { |e| e.record_id == t.id },
                                          dynamic_documents:,
                                          preview_image_attachments:,
                                          expires_at:)
        end,
        pagination: {
          count: templates.size,
          next: templates.last&.id,
          prev: templates.first&.id
        }
      }
    end

    def show
      render json: Templates::SerializeForApi.call(@template)
    end

    def create
      Params::TemplateCreateValidator.call(params)

      RateLimit.call("api-create-template-#{current_account.id}",
                     limit: CREATE_RATE_LIMIT, ttl: CREATE_RATE_TTL, enabled: true)

      attrs = create_params
      files = build_uploaded_files(attrs[:documents])
      template = persist_template(attrs, files)

      WebhookUrls.enqueue_events(template, 'template.created')
      SearchEntries.enqueue_reindex(template)

      render json: Templates::SerializeForApi.call(template)
    rescue Templates::CreateAttachments::PdfEncrypted
      render json: { error: 'The PDF is password-protected. Upload an unencrypted PDF.' },
             status: :unprocessable_content
    rescue Templates::CreateAttachments::InvalidFileType
      render json: { error: 'Unsupported document format. Only PDF and image files are supported.' },
             status: :unprocessable_content
    end

    def update
      if (folder_name = params[:folder_name] || params.dig(:template, :folder_name))
        @template.folder = TemplateFolders.find_or_create_by_name(current_user, folder_name)
      end

      Array.wrap(params[:roles].presence || params.dig(:template, :roles).presence).each_with_index do |role, index|
        if (item = @template.submitters[index])
          item['name'] = role
        else
          @template.submitters << { 'name' => role, 'uuid' => SecureRandom.uuid }
        end
      end

      archived = params.key?(:archived) ? params[:archived] : params.dig(:template, :archived)

      if archived.in?([true, false])
        @template.archived_at = archived == true ? Time.current : nil
      end

      @template.update!(template_params)

      SearchEntries.enqueue_reindex(@template)

      WebhookUrls.enqueue_events(@template, 'template.updated')
      WebhookUrls.enqueue_events(@template, 'template.archived') if archived == true

      render json: @template.as_json(only: %i[id updated_at])
    end

    def destroy
      if params[:permanently].in?(['true', true])
        @template.destroy!
      else
        @template.update!(archived_at: Time.current)

        WebhookUrls.enqueue_events(@template, 'template.archived')
      end

      render json: @template.as_json(only: %i[id archived_at])
    end

    private

    def preload_relations(templates)
      schema_documents =
        ActiveStorage::Attachment.where(record_id: templates.map(&:id),
                                        record_type: 'Template',
                                        name: :documents,
                                        uuid: templates.flat_map { |t| t.schema.pluck('attachment_uuid') })
                                 .preload(:blob)

      dynamic_document_uuids =
        templates.flat_map { |t| t.schema.select { |item| item['dynamic'] }.pluck('attachment_uuid') }

      dynamic_documents =
        if dynamic_document_uuids.present?
          DynamicDocument.where(template: templates.map(&:id))
                         .where(uuid: dynamic_document_uuids)
                         .preload(current_version: { document_attachment: :blob })
                         .select(:id, :uuid, :template_id, :sha1, :created_at, :updated_at)
        else
          DynamicDocument.none
        end

      preview_attachment_ids =
        schema_documents.map(&:id) + dynamic_documents.filter_map { |d| d.current_version&.document_attachment&.id }

      preview_image_attachments =
        ActiveStorage::Attachment.joins(:blob)
                                 .where(blob: { filename: ['0.png', '0.jpg'] })
                                 .where(record_id: preview_attachment_ids,
                                        record_type: 'ActiveStorage::Attachment',
                                        name: :preview_images)
                                 .preload(:blob)

      [schema_documents, dynamic_documents, preview_image_attachments]
    end

    def filter_templates(templates, params)
      templates = Templates.search(current_user, templates, params[:q])
      templates = params[:archived].in?(['true', true]) ? templates.archived : templates.active
      templates = templates.where(external_id: params[:application_key]) if params[:application_key].present?
      templates = templates.where(external_id: params[:external_id]) if params[:external_id].present?
      templates = templates.where(slug: params[:slug]) if params[:slug].present?

      if params[:folder].present?
        folders = TemplateFolders.filter_by_full_name(TemplateFolder.accessible_by(current_ability), params[:folder])

        templates = templates.where(folder_id: folders.pluck(:id))
      end

      templates
    end

    def template_params
      permitted_params = [
        :name,
        :external_id,
        :shared_link,
        {
          submitters: [%i[name uuid is_requester invite_by_uuid invite_via_field_uuid
                          optional_invite_by_uuid linked_to_uuid email order]],
          fields: [[:uuid, :submitter_uuid, :name, :type,
                    :required, :readonly, :default_value,
                    :title, :description, :prefillable,
                    { preferences: {},
                      default_value: [],
                      conditions: [%i[field_uuid value action operation]],
                      options: [%i[value uuid]],
                      validation: %i[message pattern min max step],
                      areas: [%i[uuid x y w h cell_w attachment_uuid option_uuid page]] }]]
        }
      ]

      if params.key?(:template)
        params.require(:template).permit(permitted_params)
      else
        params.permit(permitted_params)
      end
    end

    def create_params
      permitted_params = [
        :name, :external_id, :application_key, :folder_name,
        {
          documents: [%i[name file]],
          submitters: [%i[name role uuid]],
          fields: [[:uuid, :name, :type, :role, :required, :readonly, :title, :description, :default_value,
                    { preferences: {},
                      default_value: [],
                      options: [%i[value]],
                      areas: [%i[x y w h cell_w page document option]] }]]
        }
      ]

      scoped = params[:template].presence || params

      scoped.permit(permitted_params)
    end

    def persist_template(attrs, files)
      ActiveRecord::Base.transaction do
        template = build_template(attrs, files)

        Templates.maybe_assign_access(template)
        template.save!

        documents, = Templates::CreateAttachments.call(template, { files: files },
                                                       extract_fields: attrs[:fields].blank?)

        template.fields = build_template_fields(attrs[:fields], documents, template)
        template.update!(schema: build_schema(documents))

        template
      end
    end

    def build_template(attrs, files)
      template = Template.new(
        account: current_account,
        author: current_user,
        source: :api,
        name: template_name(attrs, files),
        submitters: build_submitters(attrs[:submitters]),
        fields: [],
        schema: []
      )

      template.external_id = attrs[:external_id].presence || attrs[:application_key].presence

      if attrs[:folder_name].present?
        template.folder = TemplateFolders.find_or_create_by_name(current_user, attrs[:folder_name])
      end

      template
    end

    def template_name(attrs, files)
      attrs[:name].presence ||
        File.basename(files.first.original_filename.to_s, '.*').presence ||
        'New Template'
    end

    def build_submitters(submitters_params)
      submitters = Array.wrap(submitters_params).filter_map do |submitter|
        name = submitter[:name].presence || submitter[:role].presence

        { 'name' => name.to_s, 'uuid' => SecureRandom.uuid } if name.present?
      end

      submitters.presence || [{ 'name' => Template::DEFAULT_SUBMITTER_NAME, 'uuid' => SecureRandom.uuid }]
    end

    def build_schema(documents)
      documents.map { |document| { 'attachment_uuid' => document.uuid, 'name' => document.filename.base } }
    end

    def build_template_fields(fields_params, documents, template)
      return Templates::ProcessDocument.normalize_attachment_fields(template, documents) if fields_params.blank?

      default_submitter_uuid = template.submitters.first['uuid']
      submitters_by_name = template.submitters.index_by { |submitter| submitter['name'] }

      fields_params.map { |field| build_field(field, documents, submitters_by_name, default_submitter_uuid) }
    end

    def build_field(field, documents, submitters_by_name, default_submitter_uuid)
      options = build_options(field[:options])

      result = {
        'uuid' => SecureRandom.uuid,
        'submitter_uuid' => submitters_by_name.dig(field[:role], 'uuid') || default_submitter_uuid,
        'name' => field[:name].to_s,
        'type' => field[:type].presence || 'text',
        'required' => field.key?(:required) ? cast_boolean(field[:required]) : true,
        'readonly' => cast_boolean(field[:readonly]),
        'preferences' => (field[:preferences] || {}).to_h,
        'areas' => build_areas(field[:areas], documents, options)
      }

      result['title'] = field[:title] if field[:title].present?
      result['description'] = field[:description] if field[:description].present?
      result['default_value'] = field[:default_value] if field[:default_value].present?
      result['options'] = options if options.present?

      result
    end

    def build_options(options_params)
      Array.wrap(options_params).map do |option|
        { 'value' => option[:value].to_s, 'uuid' => SecureRandom.uuid }
      end
    end

    def build_areas(areas_params, documents, options = [])
      Array.wrap(areas_params).map do |area|
        index = area[:document].present? ? area[:document].to_i : 0
        document = documents[index]

        if document.nil?
          raise Params::BaseValidator::InvalidParameterError, "fields area references unknown document index: #{index}"
        end

        result = {
          'attachment_uuid' => document.uuid,
          'page' => area[:page].to_i,
          'x' => area[:x].to_f,
          'y' => area[:y].to_f,
          'w' => area[:w].to_f,
          'h' => area[:h].to_f
        }

        result['cell_w'] = area[:cell_w].to_f if area[:cell_w].present?

        option_uuid = resolve_option_uuid(area[:option], options)
        result['option_uuid'] = option_uuid if option_uuid

        result
      end
    end

    def resolve_option_uuid(reference, options)
      return if reference.blank? || options.blank?

      by_value = options.find { |option| option['value'] == reference.to_s }
      return by_value['uuid'] if by_value

      index = Integer(reference, exception: false)

      options[index]['uuid'] if index && index >= 0 && index < options.size
    end

    def build_uploaded_files(documents_params)
      documents_params = Array.wrap(documents_params)

      if documents_params.size > MAX_DOCUMENTS
        raise Params::BaseValidator::InvalidParameterError, "documents must not exceed #{MAX_DOCUMENTS} items"
      end

      documents_params.map.with_index { |document, index| build_uploaded_file(document, index) }
    end

    def build_uploaded_file(document, index)
      data = decode_document_file(document[:file], index)

      tempfile = Tempfile.new
      tempfile.binmode
      tempfile.write(data)
      tempfile.rewind

      content_type = Marcel::MimeType.for(tempfile)

      unless content_type == Templates::CreateAttachments::PDF_CONTENT_TYPE || content_type.to_s.start_with?('image/')
        raise Templates::CreateAttachments::InvalidFileType, "#{content_type}/#{index}"
      end

      ActionDispatch::Http::UploadedFile.new(
        tempfile:,
        filename: document[:name].presence || "document-#{index + 1}.pdf",
        type: content_type
      )
    end

    def decode_document_file(encoded_file, index)
      encoded = encoded_file.to_s

      if encoded.bytesize > MAX_ENCODED_DOCUMENT_SIZE
        raise Params::BaseValidator::InvalidParameterError,
              "documents[#{index}].file exceeds the #{MAX_DOCUMENT_SIZE / 1.megabyte}MB limit"
      end

      data = Base64.decode64(encoded)

      if data.bytesize > MAX_DOCUMENT_SIZE
        raise Params::BaseValidator::InvalidParameterError,
              "documents[#{index}].file exceeds the #{MAX_DOCUMENT_SIZE / 1.megabyte}MB limit"
      end

      if data.blank?
        raise Params::BaseValidator::InvalidParameterError, "documents[#{index}].file is empty or not valid base64"
      end

      data
    end

    def cast_boolean(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
