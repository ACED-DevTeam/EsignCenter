# frozen_string_literal: true

module Templates
  module CreateFromApi
    MAX_DOCUMENTS = 20
    MAX_DOCUMENT_SIZE = 25.megabytes
    MAX_ENCODED_DOCUMENT_SIZE = ((MAX_DOCUMENT_SIZE * 4) / 3) + 1.kilobyte

    module_function

    def call(attrs, user:)
      # Every API door that builds a template from submitted fields (templates,
      # signing sessions, builder sessions) funnels through here.
      Templates::AssertEntitledFields.call(user.account, attrs[:fields])

      files = build_uploaded_files(attrs[:documents])

      ActiveRecord::Base.transaction do
        template = build_template(attrs, files, user:)

        Templates.maybe_assign_access(template)
        template.save!

        documents, = Templates::CreateAttachments.call(template, { files: },
                                                       extract_fields: attrs[:fields].blank?)

        template.fields = build_template_fields(attrs[:fields], documents, template)
        template.update!(schema: build_schema(documents))

        template
      end
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

      assert_pdf_or_image!(content_type, index)

      ActionDispatch::Http::UploadedFile.new(
        tempfile:,
        filename: document[:name].presence || "document-#{index + 1}.pdf",
        type: content_type
      )
    end

    # The API and MCP doors stay PDF/image-only: a Word file would start an
    # asynchronous conversion behind a synchronous contract (docs/word-uploads.md).
    def assert_pdf_or_image!(content_type, label)
      return if content_type == Templates::CreateAttachments::PDF_CONTENT_TYPE
      return if content_type.to_s.start_with?('image/')

      raise Templates::CreateAttachments::InvalidFileType, "#{content_type}/#{label}"
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

    def build_template(attrs, files, user:)
      template = Template.new(
        account: user.account,
        author: user,
        source: :api,
        name: template_name(attrs, files),
        submitters: build_submitters(attrs[:submitters]),
        fields: [],
        schema: []
      )

      template.external_id = attrs[:external_id].presence || attrs[:application_key].presence

      if attrs[:folder_name].present?
        template.folder = TemplateFolders.find_or_create_by_name(user, attrs[:folder_name])
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

    def cast_boolean(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
