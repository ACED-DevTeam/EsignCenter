# frozen_string_literal: true

module Submissions
  # The document a signer is looking at, as one PDF file.
  #
  # ESIGN §7001(c) asks the signer to confirm their device can actually display
  # the record before they agree to receive it electronically, so the consent
  # disclosure links to the unsigned original: exactly the pages the signing
  # form is showing them, nothing filled in, nothing signed.
  module OriginalDocumentPdf
    # Beyond this, merging every document into one file is a lot of memory to
    # spend answering a link a signer clicks to check their PDF reader works.
    # The first document is served instead — the first is the one the form
    # opens on, so it is the page the signer is looking at when they click —
    # and it is enough to answer the question the gate actually asks.
    MERGE_SIZE_LIMIT = 40.megabytes

    module_function

    # Exactly the documents the signer's page shows, in the order it shows
    # them: the submission's schema with its conditions applied, so a document
    # excluded by a condition is missing from the PDF too, and a reordered
    # schema reorders the pages.
    def attachments_for(submission)
      index = submission.schema_documents.preload(:blob).index_by { |a| a.metadata['original_uuid'] || a.uuid }

      Submissions.filtered_conditions_schema(submission).filter_map { |item| index[item['attachment_uuid']] }
    end

    # The same, for a template being previewed — no submission exists yet, so
    # there are no values for conditions to be evaluated against and the whole
    # schema stands.
    def template_attachments(template)
      index = template.schema_documents.preload(:blob).index_by(&:uuid)

      template.schema.filter_map { |item| index[item['attachment_uuid']] }
    end

    def call(attachments)
      attachments = Array.wrap(attachments)

      # The common case by far, and the cheap one: hand back the stored bytes
      # without opening a PDF library at all.
      return attachments.first.download if attachments.one? && !attachments.first.image?

      attachments = attachments.first(1) if attachments.sum(&:byte_size) > MERGE_SIZE_LIMIT

      return attachments.first.download if attachments.one? && !attachments.first.image?

      merge(attachments)
    end

    def merge(attachments)
      merged = attachments.each_with_object(HexaPDF::Document.new) do |attachment, document|
        pdf = load_pdf(attachment)

        pdf.pages.each { |page| document.pages << document.import(page) }
      end

      io = StringIO.new
      merged.validate(auto_correct: true)
      merged.write(io, validate: false)

      io.string
    end

    # An image template has no PDF of its own; the same conversion the result
    # documents use turns it into one page.
    def load_pdf(attachment)
      if attachment.image?
        Submissions::GenerateResultAttachments.build_pdf_from_image(attachment)
      else
        HexaPDF::Document.new(io: StringIO.new(attachment.download))
      end
    end
  end
end
