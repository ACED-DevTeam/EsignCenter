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
    # The template is saved before its file is stored; a refused file must not
    # leave that empty template behind on the dashboard.
    discard_empty_template!

    message = Templates::CreateAttachments.upload_error_message(e)

    return redirect_to(root_path, alert: message) if message

    ErrorReport.error(e)

    raise if Rails.env.local?

    redirect_to root_path, alert: I18n.t('unable_to_update_file')
  end

  private

  def discard_empty_template!
    return unless @template.persisted? && @template.schema.blank? && @template.documents.none?

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

  def create_file_params_from_url
    tempfile = Tempfile.new
    tempfile.binmode
    tempfile.write(DownloadUtils.call(params[:url], validate: true).body)
    tempfile.rewind

    filename = URI.decode_www_form_component(params[:filename]) if params[:filename].present?
    filename ||= File.basename(URI.decode_www_form_component(params[:url]))

    file = ActionDispatch::Http::UploadedFile.new(
      tempfile:,
      filename:,
      type: Marcel::MimeType.for(tempfile)
    )

    { files: [file] }
  end
end
