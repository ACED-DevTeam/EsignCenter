# frozen_string_literal: true

class TemplatesUploadsController < ApplicationController
  load_and_authorize_resource :template, parent: false

  layout 'plain'

  def show
    redirect_to root_path if params[:url].blank?
  end

  def create
    url_params = create_file_params_from_url if params[:url].present?

    save_template!(@template, url_params)

    documents, = Templates::CreateAttachments.call(@template, url_params || params, extract_fields: true)
    schema = documents.map { |doc| Templates::CreateAttachments.schema_item(doc) }

    if @template.fields.blank?
      @template.fields = Templates::ProcessDocument.normalize_attachment_fields(@template, documents)

      schema.each { |item| item['pending_fields'] = true } if @template.fields.present?
    end

    @template.update!(schema:)

    WebhookUrls.enqueue_events(@template, 'template.created')

    SearchEntries.enqueue_reindex(@template)

    redirect_to edit_template_path(@template)
  rescue Templates::CreateAttachments::PdfEncrypted
    render turbo_stream: turbo_stream.append(params[:form_id], html: helpers.tag.prompt_password)
  rescue StandardError => e
    refuse_upload!(e)
  end

  private

  # The template is saved before its files are stored, and files are stored
  # one by one: a refusal anywhere in the batch must not leave that template
  # (with whatever was attached before the refused file) behind on the
  # dashboard. A conversion job already queued for it finds nothing to do.
  def refuse_upload!(error)
    discard_template!

    message = Templates::CreateAttachments.upload_error_message(error)

    return redirect_to(root_path, alert: message) if message

    # A download that failed or was cut off at the size cap is the user's
    # condition, not a defect; anything else is reported.
    unless error.is_a?(DownloadUtils::UnableToDownload)
      ErrorReport.error(error)

      raise error if Rails.env.local?
    end

    redirect_to root_path, alert: I18n.t('unable_to_update_file')
  end

  def discard_template!
    return unless @template.persisted?

    @template.destroy!
  rescue StandardError => e
    ErrorReport.warning(e, template_id: @template.id)
  end

  def save_template!(template, url_params)
    template.account = current_account
    template.author = current_user
    template.folder = TemplateFolders.find_or_create_by_name(current_user, params[:folder_name])
    template.name = File.basename((url_params || params)[:files].first.original_filename, '.*')

    Templates.maybe_assign_access(template)

    template.save!

    template
  end

  # The download is bounded before anything is read into memory whole: a
  # Word file stops at the converter's cap (and is refused with its message),
  # anything else at the API's per-document cap.
  def create_file_params_from_url
    filename = URI.decode_www_form_component(params[:filename]) if params[:filename].present?
    filename ||= File.basename(URI.decode_www_form_component(params[:url]))

    word = Templates::CreateAttachments::DOCUMENT_EXTENSIONS.include?(File.extname(filename).downcase)
    max_bytes = word ? WordConverter::MAX_FILE_SIZE : Templates::CreateFromApi::MAX_DOCUMENT_SIZE

    body =
      begin
        DownloadUtils.call(params[:url], validate: true, max_bytes:).body
      rescue DownloadUtils::TooLarge
        raise WordConverter::FileTooLarge if word

        raise
      end

    tempfile = Tempfile.new
    tempfile.binmode
    tempfile.write(body)
    tempfile.rewind

    file = ActionDispatch::Http::UploadedFile.new(
      tempfile:,
      filename:,
      type: Marcel::MimeType.for(tempfile)
    )

    { files: [file] }
  end
end
