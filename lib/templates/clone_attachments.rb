# frozen_string_literal: true

module Templates
  # Copying a template's documents onto a new template WITHOUT re-uploading a
  # byte: the new attachment rows point at the original's blobs. That is what
  # makes cloning instant, and it is also why one file can belong to two
  # templates — and, when a template is shared across a link, to two accounts.
  module CloneAttachments
    module_function

    def call(template:, original_template:, documents: [], excluded_attachment_uuids: [], save: true)
      schema_uuids_replacements = {}

      template.schema.each_with_index do |schema_item, index|
        attachment_uuid = schema_item['attachment_uuid'] || schema_item[:attachment_uuid]

        next if excluded_attachment_uuids.include?(attachment_uuid)

        new_schema_item_uuid = SecureRandom.uuid

        schema_uuids_replacements[attachment_uuid] = new_schema_item_uuid
        schema_item.delete(:attachment_uuid)
        schema_item['attachment_uuid'] = new_schema_item_uuid

        new_name = documents&.dig(index, 'name')

        schema_item['name'] = new_name if new_name.present?
      end

      template.fields.each do |field|
        next if field['areas'].blank?

        field['areas'].each do |area|
          new_attachment_uuid = schema_uuids_replacements[area['attachment_uuid']]
          area['attachment_uuid'] = new_attachment_uuid if new_attachment_uuid
        end
      end

      attachments =
        original_template.schema_documents.filter_map do |document|
          new_attachment_uuid = schema_uuids_replacements[document.uuid]

          next unless new_attachment_uuid

          new_document =
            template.documents_attachments.new(uuid: new_attachment_uuid, blob_id: document.blob_id)

          maybe_clone_dynamic_document(template, original_template, new_document, document)
          clone_document_preview_images_attachments(document:, new_document:)

          new_document
        end

      save_under_blob_locks!(template) if save

      attachments
    end

    # The new rows are inserted while every blob they reuse is held under
    # `SELECT ... FOR UPDATE` (review 8, A1).
    #
    # Accounts::Purge decides whether a file is shared and then deletes it,
    # and it takes the same lock to make those one decision. Without this the
    # clone could land in the gap between them: the purge would have already
    # decided the file was nobody else's, and its delete takes EVERY row
    # naming the blob — so a template cloned out of an account that was being
    # purged lost its document, and the file with it, permanently. Locking
    # here means the clone either commits before the purge looks (and is
    # honoured, the file kept) or waits until the blob is gone (and fails on
    # the foreign key, leaving no template pointing at nothing).
    #
    # Ordered by id, so two clones reusing the same two files can never take
    # them in opposite orders and deadlock. Nothing is locked when the clone
    # reuses no blobs at all.
    #
    # `save: false` callers own their own insert and get no protection — there
    # are none today; every caller lets this method save.
    def save_under_blob_locks!(template)
      blob_ids = reused_blob_ids(template)

      return template.save! if blob_ids.empty?

      ApplicationRecord.transaction do
        ActiveStorage::Blob.where(id: blob_ids).order(:id).lock.pluck(:id)

        template.save!
      end
    end

    # Every blob the about-to-be-saved rows point at: the documents, the
    # attachments of any dynamic document cloned with them, and the page
    # preview images hanging off each document.
    def reused_blob_ids(template)
      documents = template.documents_attachments.select(&:new_record?)

      previews = documents.flat_map { |document| document.preview_images_attachments.to_a }
      dynamic = template.dynamic_documents.select(&:new_record?)
                        .flat_map { |dynamic_document| dynamic_document.attachments_attachments.to_a }

      (documents + previews + dynamic).filter_map(&:blob_id).uniq
    end

    def maybe_clone_dynamic_document(template, original_template, document, original_document)
      schema_item = original_template.schema.find { |e| e['attachment_uuid'] == original_document.uuid }

      return unless schema_item
      return unless schema_item['dynamic']

      dynamic_document = original_template.dynamic_documents.find { |e| e.uuid == original_document.uuid }

      return unless dynamic_document

      new_dynamic_document = template.dynamic_documents.new(
        uuid: document.uuid,
        body: dynamic_document.body,
        head: dynamic_document.head
      )

      dynamic_document.attachments_attachments.each do |attachment|
        new_dynamic_document.attachments_attachments.new(
          uuid: attachment.uuid,
          blob_id: attachment.blob_id
        )
      end

      new_dynamic_document
    end

    def clone_document_preview_images_attachments(document:, new_document:)
      document.preview_images_attachments.each do |preview_image|
        new_document.preview_images_attachments.new(blob_id: preview_image.blob_id)
      end
    end
  end
end
