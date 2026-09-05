# frozen_string_literal: true

module Submissions
  # The document a signer is looking at, as one PDF file.
  #
  # ESIGN §7001(c) asks the signer to confirm their device can actually display
  # the record before they agree to receive it electronically, so the consent
  # disclosure links to the unsigned original: exactly the pages the signing
  # form is showing them, nothing filled in, nothing signed.
  #
  # A template can carry several documents, and image templates carry no PDF at
  # all, so the pages are merged into one file here. The single-PDF case — much
  # the most common one — is answered with the stored bytes untouched, so the
  # cheap path stays cheap.
  module OriginalDocumentPdf
    module_function

    def call(attachments)
      attachments = Array.wrap(attachments)

      return attachments.first.download if attachments.one? && !attachments.first.image?

      merged = attachments.each_with_object(HexaPDF::Document.new) do |attachment, document|
        pdf = load_pdf(attachment)

        pdf.pages.each { |page| document.pages << document.import(page) }
      end

      io = StringIO.new
      merged.validate(auto_correct: true)
      merged.write(io, validate: false)

      io.string
    end

    def load_pdf(attachment)
      if attachment.image?
        Submissions::GenerateResultAttachments.build_pdf_from_image(attachment)
      else
        HexaPDF::Document.new(io: StringIO.new(attachment.download))
      end
    end
  end
end
