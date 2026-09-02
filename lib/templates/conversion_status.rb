# frozen_string_literal: true

module Templates
  # What the builder polls while a Word document is being converted: the
  # attachment's own metadata is the source of truth (the schema the builder
  # autosaves may lag behind it), and a ready document comes back in the same
  # shape the add-document response uses, so the builder can swap it in.
  module ConversionStatus
    DOCUMENT_JSON = {
      methods: %i[metadata signed_key],
      include: { preview_images: { methods: %i[url metadata filename] } }
    }.freeze

    module_function

    def call(template, attachment_uuid)
      document = template.documents.preload(:blob, { preview_images_attachments: :blob }).find_by(uuid: attachment_uuid)

      return if document.nil?

      status = status_for(document)
      schema_item = schema_item_for(template, document, status)

      result = { status:, schema_item: }

      if status == 'ready'
        result[:document] = document.as_json(DOCUMENT_JSON)
        result[:fields] = template.fields
        result[:submitters] = template.submitters
      end

      result
    end

    def status_for(document)
      if document.metadata['converting']
        'converting'
      elsif document.metadata['conversion_failed']
        'failed'
      else
        'ready'
      end
    end

    def schema_item_for(template, document, status)
      item = template.schema.find { |e| e['attachment_uuid'] == document.uuid }
      item = item&.except('converting', 'conversion_failed') ||
             { 'attachment_uuid' => document.uuid, 'name' => document.filename.base }

      item['converting'] = true if status == 'converting'
      item['conversion_failed'] = true if status == 'failed'

      item
    end
  end
end
