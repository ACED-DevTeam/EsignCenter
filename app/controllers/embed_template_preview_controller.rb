# frozen_string_literal: true

# Public, read-only render of a template's signing form for a paired app's
# iframe. Authenticated only by the signed preview token in the URL (minted by
# Api::TemplatePreviewSessionsController), which also names the single origin
# allowed to frame the page.
#
# Nothing here writes: the submitter and submission are in-memory throwaways and
# the form is rendered with `dry_run: true`, so the signing form cannot submit.
class EmbedTemplatePreviewController < ApplicationController
  include ActiveStorage::Streaming

  layout 'form'

  # Field types whose stored value is a plain string the signing form paints
  # straight onto the page (see app/views/submissions/_value.html.erb). Every
  # OTHER type — signature, image, initials, file, stamp, payment, verification,
  # kba — resolves its value through `attachments_index[value]`, i.e. an
  # ActiveStorage attachment that a made-up preview string can never match, so a
  # dummy value for one of those would raise instead of rendering.
  TEXTUAL_FIELD_TYPES = %w[text number date select radio checkbox cells phone].freeze

  # Preview pages are dead ends by design: the viewer is a guest of the paired
  # app with no session here, so nothing on the page may steer their browser to
  # a configured destination. These carry URLs and are blanked below.
  SCRUBBED_TEMPLATE_PREFERENCE_KEYS = %w[completed_redirect_url completed_message].freeze

  skip_before_action :authenticate_user!
  skip_authorization_check
  skip_forgery_protection

  before_action :load_preview_session
  before_action :set_embed_frame_headers

  rescue_from Entitlements::UpgradeRequired do |e|
    render json: { error: Entitlements.refusal_message(e.feature) }, status: :forbidden
  end

  def document
    attachments = Submissions::OriginalDocumentPdf.template_attachments(@template)

    return head :not_found if attachments.blank?

    # Keep every PDF request behind this preview's expiry and current account
    # checks. A generic blob redirect would mint a second bearer credential,
    # and that proxy's public cache could outlive the preview entirely.
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Pragma'] = 'no-cache'

    if (blob = Submissions::OriginalDocumentPdf.single_pdf(attachments)&.blob)
      return send_blob_stream(blob, disposition: 'inline')
    end

    send_data Submissions::OriginalDocumentPdf.call(attachments),
              filename: "#{@template.name}.pdf", type: 'application/pdf', disposition: 'inline'
  end

  def show
    account = @template.account

    @submitter = Submitter.new(uuid: @template.submitters.first['uuid'],
                               account:,
                               values: @preview_values,
                               submission: @template.submissions.new(template_submitters: @template.submitters,
                                                                     account:))

    @submitter.submission.submitters =
      @template.submitters.map { |item| Submitter.new(uuid: item['uuid'], values: @preview_values) }

    Submissions.preload_with_pages(@submitter.submission)

    @attachments_index = ActiveStorage::Attachment.where(record: @submitter.submission.submitters, name: :attachments)
                                                  .preload(:blob).index_by(&:uuid)

    @form_configs = scrub_form_configs(Submitters::FormConfigs.call(@submitter))
  end

  private

  def load_preview_session
    payload = TemplatePreviewSessions.read_token(params[:token])

    raise ActionController::RoutingError, I18n.t('not_found') if payload.blank?

    @template = Template.find_by(id: payload[:template_id], account_id: payload[:account_id])

    raise ActionController::RoutingError, I18n.t('not_found') if @template.nil? || @template.submitters.blank?

    raise ActionController::RoutingError, I18n.t('not_found') unless AccountStates.tokens_allowed?(@template.account)

    Entitlements.require!(@template.account, :embed)

    @preview_origin = payload[:origin].presence
    @preview_values = renderable_preview_values(payload[:values].presence || {})

    scrub_template_preferences
  end

  # The token carries whatever strings the paired app felt like sending. Keep
  # only the ones that name a real field of THIS template (by uuid or by name)
  # and that the form can paint as text, then re-key them to the field uuid the
  # form actually looks up. Everything else is dropped, so a preview renders
  # rather than erroring on a value it could never resolve.
  def renderable_preview_values(values)
    return {} if values.blank?

    fields_index = {}

    Array.wrap(@template.fields).each do |field|
      fields_index[field['uuid'].to_s] = field if field['uuid'].present?
      fields_index[field['name'].to_s] ||= field if field['name'].present?
    end

    values.to_h.filter_map do |key, value|
      field = fields_index[key.to_s]

      next if field.nil? || TEXTUAL_FIELD_TYPES.exclude?(field['type'].to_s)

      [field['uuid'].to_s, value.to_s]
    end.to_h
  end

  # `@template` is a throwaway load for this request and is never saved, so
  # blanking the preference keys in memory is enough — and `readonly!` turns any
  # future accidental write on this path into a loud error rather than a silent
  # change to a real template.
  def scrub_template_preferences
    preferences = @template.preferences

    @template.preferences = preferences.except(*SCRUBBED_TEMPLATE_PREFERENCE_KEYS) if preferences.is_a?(Hash)

    @template.readonly!
  end

  # The account's own completed-button URL, completed message and policy links
  # are real links out of the preview; a preview has nowhere to go.
  def scrub_form_configs(configs)
    configs.merge(completed_button: {}, completed_message: {}, policy_links: nil)
  end

  def set_embed_frame_headers
    response.headers.delete('X-Frame-Options')
    request.content_security_policy&.frame_ancestors(:self, @preview_origin)
  end
end
