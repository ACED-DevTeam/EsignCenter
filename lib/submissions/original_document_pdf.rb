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
    #
    # `submitter` is the person the link is being answered for, and it has to
    # be passed whenever there is one. The signing page filters the schema
    # with `include_submitter_uuid` (show.html.erb), which reads a condition
    # on that signer's OWN field as satisfied — it is the field they are about
    # to fill in, so the document is on screen in front of them. Evaluating
    # the same condition without it answers a narrower set than the page
    # shows, and the door 404s on a document the signer is looking at. The
    # merged submitter values the page passes are what
    # `filtered_conditions_schema` computes for itself when none are given
    # (submissions.rb), so only the uuid has to travel.
    def attachments_for(submission, submitter: nil)
      index = submission.schema_documents.preload(:blob).index_by { |a| a.metadata['original_uuid'] || a.uuid }

      Submissions.filtered_conditions_schema(submission, include_submitter_uuid: submitter&.uuid)
                 .filter_map { |item| index[item['attachment_uuid']] }
    end

    # The same, for a template being previewed — no submission exists yet, so
    # there are no values for conditions to be evaluated against and the whole
    # schema stands.
    def template_attachments(template)
      index = template.schema_documents.preload(:blob).index_by(&:uuid)

      template.schema.filter_map { |item| index[item['attachment_uuid']] }
    end

    # What the "View this document as a PDF" link will serve for this form —
    # the signing page asks so the link can say "the first document" when the
    # cap is going to truncate.
    def form_attachments(submitter, dry_run: false)
      return attachments_for(submitter.submission, submitter:) unless dry_run

      template = submitter.submission.template

      template ? template_attachments(template) : []
    end

    # The one document a caller can serve straight from storage, without
    # reading it into the app at all: a single PDF, either because that is the
    # whole form or because the merge cap left only the first one. nil when
    # the pages have to be built (images, or several documents to merge).
    def single_pdf(attachments)
      attachments = servable(attachments)

      attachments.first if attachments.one? && !attachments.first.image?
    end

    # Did the cap leave documents out of what the link will serve?
    def truncated?(attachments)
      attachments = Array.wrap(attachments)

      attachments.size > 1 && over_cap?(attachments)
    end

    def call(attachments)
      merge(servable(attachments))
    end

    def servable(attachments)
      attachments = Array.wrap(attachments)

      over_cap?(attachments) ? attachments.first(1) : attachments
    end

    def over_cap?(attachments)
      attachments.sum(&:byte_size) > MERGE_SIZE_LIMIT
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
