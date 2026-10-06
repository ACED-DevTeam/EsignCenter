# frozen_string_literal: true

module Templates
  module CreateAttachments
    PDF_CONTENT_TYPE = 'application/pdf'
    ZIP_CONTENT_TYPE = 'application/zip'
    X_ZIP_CONTENT_TYPE = 'application/x-zip-compressed'
    JSON_CONTENT_TYPE = 'application/json'
    # Word documents are the only non-PDF, non-image format accepted; they
    # are converted to PDF in the background (WordConverter, docs/word-uploads.md).
    DOCUMENT_EXTENSIONS = %w[.docx .doc].freeze

    DOCUMENT_CONTENT_TYPES = %w[
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      application/msword
    ].freeze

    ANNOTATIONS_SIZE_LIMIT = 6.megabytes
    MAX_ZIP_SIZE = 100.megabytes
    WORD_CONVERSIONS_PER_HOUR = 30
    InvalidFileType = Class.new(StandardError)
    PdfEncrypted = Class.new(StandardError)

    # Refusals a user can act on, keyed by the i18n message they get. Anything
    # else that goes wrong stays a generic "unable to upload" error.
    UPLOAD_ERROR_KEYS = {
      WordConverter::Unavailable => 'word_conversion_unavailable',
      WordConverter::FileTooLarge => 'word_file_too_large',
      RateLimit::LimitApproached => 'too_many_word_conversions',
      InvalidFileType => 'unsupported_document_format'
    }.freeze
    # The same refusal while Word conversion is off: the upload forms no
    # longer offer Word files then, so the message must not invite one.
    UNSUPPORTED_FORMAT_PDF_IMAGE_ONLY_KEY = 'unsupported_document_format_pdf_image_only'

    # The API, MCP and signing-session refusal for anything but a PDF or an
    # image (Word is a dashboard-only format): one wording, quoted verbatim by
    # the golden specs.
    UNSUPPORTED_FORMAT_API_MESSAGE = 'Unsupported document format. Only PDF and image files are supported. ' \
                                     'Convert Word documents to PDF before uploading, or upload them from ' \
                                     'the dashboard.'

    BASE_ACCEPT_FILE_TYPES = 'image/*, application/pdf, application/zip, application/json'

    module_function

    # The `accept` list for the builder's own upload inputs once Word is on
    # (the dashboard forms build the same list inline).
    def builder_accept_file_types
      "#{BASE_ACCEPT_FILE_TYPES}, #{DOCUMENT_EXTENSIONS.join(', ')}"
    end

    # Every account-user upload path stores its files through here (dashboard
    # upload, builder "add document", embedded builder, API, MCP, clone-and-
    # replace, builder sessions), so the storage cap is asked once, here,
    # after zip extraction and before any blob is created; what the answer
    # is depends on the account, never on the door.
    def call(template, params, extract_fields: false, dynamic: false)
      documents = []
      dynamic_documents = []

      files = extract_zip_files(params[:files].presence || params[:file])

      Quotas::Storage.assert_available!(template.account, Quotas::Storage.incoming_bytes(files))

      files.each do |file|
        docs, dynamic_docs = handle_file_types(template, file, params, extract_fields:, dynamic:)

        documents.push(*docs)
        dynamic_documents.push(*dynamic_docs)
      end

      Quotas::Storage.after_upload(template.account) if documents.present?

      [documents, dynamic_documents]
    end

    # `content_type` is the sniffed type (handle_file_types); the declared one
    # is only a fallback for callers that already know what they hold.
    def handle_pdf_or_image(template, file, document_data = nil, params = {}, extract_fields: false, metadata: {},
                            content_type: nil)
      document_data ||= file.read
      content_type ||= file.content_type

      document_data = maybe_decrypt_pdf_or_raise(document_data, params) if content_type == PDF_CONTENT_TYPE

      blob = build_document_blob(document_data, filename: file.original_filename, content_type:, metadata:)

      document = template.documents.create!(blob:)

      process_pdf_attachment(document, document_data, extract_fields:)
    end

    # The blob a PDF or image document is stored as: annotations are read up
    # front for PDFs (the builder draws them), and every blob carries its
    # sha256. Shared with the Word conversion job, which stores its PDF the
    # same way.
    def build_document_blob(document_data, filename:, content_type:, metadata: {})
      if content_type == PDF_CONTENT_TYPE
        annotations =
          document_data.size < ANNOTATIONS_SIZE_LIMIT ? Templates::BuildAnnotations.call(document_data) : []
      end

      sha256 = Base64.urlsafe_encode64(Digest::SHA256.digest(document_data))

      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(document_data),
        filename:,
        metadata: {
          **metadata,
          identified: content_type == PDF_CONTENT_TYPE,
          analyzed: content_type == PDF_CONTENT_TYPE,
          pdf: { annotations: }.compact_blank, sha256:
        }.compact_blank,
        content_type:
      )
    end

    # Page count, preview images and (optionally) the form fields found in the
    # file. Runs inline for PDF and image uploads and from the conversion job
    # once a Word document has become a PDF.
    def process_pdf_attachment(attachment, document_data, extract_fields: false)
      Templates::ProcessDocument.call(attachment, document_data, extract_fields:)
    end

    # A Word document is stored as uploaded and handed to the conversion
    # queue; the attachment is returned in the same position a PDF would be,
    # flagged `converting` until the job swaps the PDF in.
    def handle_word_document(template, file, document_data, content_type:)
      raise WordConverter::Unavailable unless WordConverter.enabled?
      raise WordConverter::FileTooLarge if document_data.bytesize > WordConverter::MAX_FILE_SIZE

      RateLimit.call("word-conversion-#{template.account_id}", limit: WORD_CONVERSIONS_PER_HOUR, ttl: 1.hour)

      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(document_data),
        filename: file.original_filename,
        content_type:,
        metadata: {
          identified: true,
          analyzed: true,
          'converting' => true,
          'original_filename' => file.original_filename,
          sha256: Base64.urlsafe_encode64(Digest::SHA256.digest(document_data))
        }
      )

      attachment = template.documents.create!(blob:)

      ConvertWordDocumentJob.perform_async('template_id' => template.id, 'attachment_uuid' => attachment.uuid)

      attachment
    end

    # The schema entry a freshly stored document gets; a Word document still
    # being converted carries `converting: true` so every reader (builder,
    # send page) shows a placeholder instead of pages.
    def schema_item(document)
      item = { attachment_uuid: document.uuid, name: document.filename.base }
      item[:converting] = true if document.metadata['converting']

      item
    end

    # The user-facing message for a refusal raised by `call`, or nil when the
    # error is not one the user can act on.
    def upload_error_message(error)
      # The storage refusal carries its own numbers (used, limit).
      return error.localized_message if error.is_a?(Quotas::StorageLimitReached)

      key = UPLOAD_ERROR_KEYS.find { |klass, _| error.is_a?(klass) }&.last

      # An oversized zip is a different problem from an unknown format.
      return if key.nil? || (error.is_a?(InvalidFileType) && error.message == 'zip_too_large')

      key = UNSUPPORTED_FORMAT_PDF_IMAGE_ONLY_KEY if key == 'unsupported_document_format' && !WordConverter.enabled?

      I18n.t(key, limit_mb: WordConverter::MAX_FILE_SIZE / 1.megabyte)
    end

    def maybe_decrypt_pdf_or_raise(data, params)
      if data.size < ANNOTATIONS_SIZE_LIMIT && PdfUtils.encrypted?(data)
        PdfUtils.decrypt(data, params[:password])
      else
        data
      end
    rescue HexaPDF::EncryptionError
      raise PdfEncrypted
    end

    # What the bytes say the file is (Marcel reads the magic numbers, then the
    # name and the declared type only to refine them). Every upload is routed
    # by this, never by the browser's declared type: a .docx is a zip inside,
    # and a renamed file is whatever it really is.
    def sniff_content_type(file)
      io = file.respond_to?(:tempfile) ? file.tempfile : file
      io.rewind if io.respond_to?(:rewind)

      type = Marcel::MimeType.for(io, name: file.original_filename.to_s, declared_type: file.content_type.to_s)

      io.rewind if io.respond_to?(:rewind)

      type
    end

    def zip?(content_type)
      content_type == ZIP_CONTENT_TYPE || content_type == X_ZIP_CONTENT_TYPE
    end

    def extract_zip_files(files)
      extracted_files = []

      Array.wrap(files).each do |file|
        if zip?(sniff_content_type(file))
          total_size = 0

          Zip::File.open(file.tempfile).each do |entry|
            next if entry.directory?

            total_size += entry.size

            raise InvalidFileType, 'zip_too_large' if total_size > MAX_ZIP_SIZE

            tempfile = Tempfile.new(entry.name)
            tempfile.binmode
            entry.get_input_stream { |in_stream| IO.copy_stream(in_stream, tempfile) }
            tempfile.rewind

            type = Marcel::MimeType.for(tempfile, name: entry.name)

            next if type.exclude?('image') &&
                    type != PDF_CONTENT_TYPE &&
                    type != JSON_CONTENT_TYPE &&
                    DOCUMENT_CONTENT_TYPES.exclude?(type)

            extracted_files << ActionDispatch::Http::UploadedFile.new(
              filename: File.basename(entry.name),
              type:,
              tempfile:
            )
          end
        else
          extracted_files << file
        end
      end

      extracted_files
    end

    def handle_file_types(template, file, params, extract_fields:, dynamic: false)
      content_type = sniff_content_type(file)

      if content_type.include?('image') || content_type == PDF_CONTENT_TYPE
        return [handle_pdf_or_image(template, file, file.read, params, extract_fields:, content_type:), []]
      end

      if WordConverter.word?(content_type:, filename: file.original_filename)
        # The size is known before a byte of the upload is read into memory;
        # handle_word_document checks the bytes it got once more.
        raise WordConverter::FileTooLarge if file.respond_to?(:size) && file.size.to_i > WordConverter::MAX_FILE_SIZE

        return [handle_word_document(template, file, file.read, content_type:), []]
      end

      raise InvalidFileType, "#{content_type}/#{dynamic}"
    end
  end
end
