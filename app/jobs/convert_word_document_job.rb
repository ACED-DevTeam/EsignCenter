# frozen_string_literal: true

# Turns an uploaded Word document into the PDF the template actually uses.
# Runs on the low-concurrency `documents` queue; the converter itself holds a
# process-wide slot and a hard timeout. A document that cannot be converted is
# marked failed and reported once — no Sidekiq retry, the outcome would be the
# same. Storage and database errors are left to raise so Sidekiq retries them.
class ConvertWordDocumentJob
  include Sidekiq::Job

  sidekiq_options queue: :documents, retry: 3

  BUSY_RETRY_DELAY = 15.seconds
  # About ten minutes of waiting for a free slot before giving up.
  MAX_BUSY_RETRIES = 40

  def perform(params = {})
    template = Template.find_by(id: params['template_id'])
    attachment = template && template.documents.preload(:blob).find_by(uuid: params['attachment_uuid'])

    return if attachment.nil? || !attachment.metadata['converting']

    busy_retries = params['busy_retries'].to_i

    if busy_retries >= MAX_BUSY_RETRIES
      return fail_conversion(template, attachment,
                             WordConverter::Busy.new("no conversion slot after #{busy_retries} retries"))
    end

    word_blob = attachment.blob
    filename = attachment.metadata['original_filename'].presence || word_blob.filename.to_s

    pdf_data = WordConverter.with_slot { WordConverter.call(word_blob.download, filename:) }

    store_pdf(template, attachment, pdf_data, filename:)

    word_blob.purge_later
  rescue WordConverter::Busy
    self.class.perform_in(BUSY_RETRY_DELAY, params.merge('busy_retries' => busy_retries + 1))
  rescue WordConverter::TimeoutError, WordConverter::ConversionError, WordConverter::Unavailable => e
    fail_conversion(template, attachment, e)
  end

  private

  def store_pdf(template, attachment, pdf_data, filename:)
    pdf_blob = Templates::CreateAttachments.build_document_blob(
      pdf_data,
      filename: "#{File.basename(filename, '.*')}.pdf",
      content_type: Templates::CreateAttachments::PDF_CONTENT_TYPE,
      metadata: { 'original_filename' => filename }
    )

    attachment.blob = pdf_blob
    attachment.save!

    Templates::CreateAttachments.process_pdf_attachment(attachment, pdf_data, extract_fields: true)

    fields = Templates::ProcessDocument.normalize_attachment_fields(template, [attachment])

    attachment.save!

    update_schema_item(template, attachment.uuid) do |item|
      item.delete('converting')
      item.delete('conversion_failed')
      item['pending_fields'] = true if fields.present?
    end

    template.update!(fields: template.fields + fields) if fields.present?
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

  # The builder autosaves the whole schema, so the entry is re-read right
  # before it is rewritten to keep the window for a lost update small.
  def update_schema_item(template, attachment_uuid)
    template.reload

    schema = template.schema.deep_dup
    item = schema.find { |e| e['attachment_uuid'] == attachment_uuid }

    return if item.nil?

    yield item

    template.update!(schema:)
  end
end
