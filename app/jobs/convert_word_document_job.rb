# frozen_string_literal: true

# Turns an uploaded Word document into the PDF the template actually uses.
# Runs on the low-concurrency `documents` queue; the converter itself holds a
# process-wide slot and a hard timeout. A document that cannot be converted is
# marked failed and reported once — no Sidekiq retry, the outcome would be the
# same. Storage and database errors are left to raise so Sidekiq retries them.
#
# The job is resumable: the PDF blob is swapped in with `converting` still set
# and a `conversion_stage` marker, so a retry that finds the PDF already
# stored skips LibreOffice and only redoes the post-processing (page count,
# previews, field extraction — all idempotent). The Word blob is purged last.
class ConvertWordDocumentJob
  include Sidekiq::Job

  sidekiq_options queue: :documents, retry: 3

  BUSY_RETRY_DELAY = 15.seconds
  # About ten minutes of waiting for a free slot before giving up.
  MAX_BUSY_RETRIES = 40
  STAGE_PDF_STORED = 'pdf_stored'

  def perform(params = {})
    template = Template.find_by(id: params['template_id'])
    attachment = template && template.documents.preload(:blob).find_by(uuid: params['attachment_uuid'])

    return if attachment.nil? || !(attachment.metadata['converting'] || attachment.metadata['conversion_failed'])

    # A retry after the blob swap: the PDF is there, only the rest is owed.
    return finish_conversion(template, attachment) if attachment.metadata['conversion_stage'] == STAGE_PDF_STORED

    busy_retries = params['busy_retries'].to_i

    if busy_retries >= MAX_BUSY_RETRIES
      return fail_conversion(template, attachment,
                             WordConverter::Busy.new("no conversion slot after #{busy_retries} retries"))
    end

    word_blob = attachment.blob
    filename = attachment.metadata['original_filename'].presence || word_blob.filename.to_s

    pdf_data = WordConverter.with_slot { WordConverter.call(word_blob.download, filename:) }

    store_pdf(attachment, pdf_data, filename:, word_blob:)

    finish_conversion(template, attachment, pdf_data)
  rescue WordConverter::Busy
    self.class.perform_in(BUSY_RETRY_DELAY, params.merge('busy_retries' => busy_retries + 1))
  rescue WordConverter::TimeoutError, WordConverter::ConversionError, WordConverter::Unavailable => e
    fail_conversion(template, attachment, e)
  end

  private

  # Swaps the PDF blob into the attachment (same uuid). `converting` stays on
  # and the stage marker plus the Word blob's id let a retry resume from here.
  def store_pdf(attachment, pdf_data, filename:, word_blob:)
    pdf_blob = Templates::CreateAttachments.build_document_blob(
      pdf_data,
      filename: "#{File.basename(filename, '.*')}.pdf",
      content_type: Templates::CreateAttachments::PDF_CONTENT_TYPE,
      metadata: {
        'original_filename' => filename,
        'converting' => true,
        'conversion_stage' => STAGE_PDF_STORED,
        'word_blob_id' => word_blob.id
      }
    )

    attachment.blob = pdf_blob
    attachment.save!
  end

  # Page count, preview images and the fields found in the PDF. The fields
  # stay in the attachment's metadata (`pdf.fields`), exactly as a PDF added
  # from the builder leaves them: the builder merges and saves them itself
  # when the status poll reports `ready`, so this job never rewrites
  # `template.fields` underneath an open builder.
  def finish_conversion(template, attachment, pdf_data = nil)
    pdf_data ||= attachment.download

    Templates::CreateAttachments.process_pdf_attachment(attachment, pdf_data, extract_fields: true)

    attachment.metadata.delete('converting')
    attachment.metadata.delete('conversion_stage')
    word_blob_id = attachment.metadata.delete('word_blob_id')
    attachment.save!

    update_schema_item(template, attachment.uuid) do |item|
      item.delete('converting')
      item.delete('conversion_failed')
    end

    ActiveStorage::Blob.find_by(id: word_blob_id)&.purge_later if word_blob_id

    nil
  end

  def fail_conversion(template, attachment, error)
    attachment.metadata.delete('converting')
    attachment.metadata['conversion_failed'] = true
    attachment.save!

    update_schema_item(template, attachment.uuid) do |item|
      item.delete('converting')
      item['conversion_failed'] = true
    end

    ErrorReport.warning(error, template_id: template.id, attachment_uuid: attachment.uuid)

    nil
  end

  # The schema flags are a cache of the attachment metadata (the builder's
  # own saves re-derive them too, Templates.refresh_conversion_flags); the
  # entry is re-read right before it is rewritten to keep the window small.
  def update_schema_item(template, attachment_uuid)
    template.reload

    schema = template.schema.deep_dup
    item = schema.find { |e| e['attachment_uuid'] == attachment_uuid }

    return if item.nil?

    yield item

    template.update!(schema:)
  end
end
