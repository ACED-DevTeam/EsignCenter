# frozen_string_literal: true

class SubmitFormController < ApplicationController
  include CompletedFormMarker

  layout 'form'

  # `update` included: a consent recorded without a page-sent locale falls
  # back to the same browser locale `show` rendered the disclosure under.
  around_action :with_browser_locale, only: %i[show update completed success delegated]
  skip_before_action :authenticate_user!
  skip_authorization_check
  skip_before_action :verify_authenticity_token, only: :update

  before_action :load_submitter, only: %i[show update completed]
  before_action :set_embed_frame_headers, only: %i[show completed]
  before_action :maybe_redirect_delegated, only: %i[show completed]
  before_action :maybe_render_locked_page, only: :show
  before_action :maybe_require_link_2fa, only: %i[show]

  CONFIG_KEYS = [].freeze

  # The Vue form maps this error key to the required message at the consent
  # checkbox (see app/javascript/submission_form/form.vue).
  rescue_from EsignConsent::ConsentRequiredError do
    render json: { error: 'esign_consent_required' }, status: :unprocessable_content
  end

  # The page showed an older disclosure than the one now in force: the form
  # asks the signer to reload and agree again.
  rescue_from EsignConsent::StaleVersionError do
    render json: { error: 'esign_consent_version_stale' }, status: :unprocessable_content
  end

  def show
    submission = @submitter.submission

    return render :email_2fa unless Submitters::AuthorizedForForm.pass_email_2fa?(@submitter, request)
    return redirect_to submit_form_completed_path(@submitter.slug) if @submitter.completed_at?

    @form_configs = Submitters::FormConfigs.call(@submitter, CONFIG_KEYS)

    # Shared with the "View this document as a PDF" door beside the consent
    # checkbox, so the two refuse on identical terms (Submitters::FormOpen).
    return render :awaiting if Submitters::FormOpen.awaiting_turn?(@submitter, form_configs: @form_configs)

    Submissions.preload_with_pages(submission)

    Submitters::MaybeUpdateDefaultValues.call(@submitter, current_user)

    @attachments_index = build_attachments_index(submission)

    return unless @form_configs[:prefill_signature]

    if (user_signature = UserConfigs.load_signature(current_user))
      @signature_attachment = ActiveStorage::Attachment.find_or_create_by!(
        blob_id: user_signature.blob_id,
        name: 'attachments',
        record: @submitter
      )
    end

    @signature_attachment ||=
      Submitters::MaybeAssignDefaultBrowserSignature.call(@submitter, params, cookies, @attachments_index.values)

    @attachments_index[@signature_attachment.uuid] = @signature_attachment if @signature_attachment
  end

  def update
    unless Submitters::AuthorizedForForm.call(@submitter, current_user, request)
      return render json: { error: I18n.t('verification_required_refresh_the_page_and_pass_2fa') },
                    status: :unprocessable_content
    end

    if @submitter.completed_at?
      return render json: { error: I18n.t('form_has_been_completed_already') }, status: :unprocessable_content
    end

    if locked_for_writing?
      return render json: { error: I18n.t('form_has_been_archived') }, status: :unprocessable_content
    end

    if @submitter.submission.expired?
      return render json: { error: I18n.t('form_has_been_expired') }, status: :unprocessable_content
    end

    if @submitter.declined_at?
      return render json: { error: I18n.t('form_has_been_declined') },
                    status: :unprocessable_content
    end

    Submitters::SubmitValues.call(@submitter, params, request)

    # This request IS the completion, so this browser is the one that made it:
    # it gets the marker that lets the share link's completed page name the
    # document to them later, and nobody has to guess an identity from an IP
    # address to hand it out (CompletedFormMarker).
    remember_completed_form(@submitter)

    if params[:completed] == 'true' && @submitter.submission.source_embed?
      return render json: embed_completion_response(@submitter.reload)
    end

    head :ok
  rescue Submitters::SubmitValues::RequiredFieldError => e
    ErrorReport.warning("Required field #{@submitter.id}: #{e.message}")

    render json: { field_uuid: e.message }, status: :unprocessable_content
  rescue Submitters::SubmitValues::ValidationError => e
    ErrorReport.warning("Validation error #{@submitter.id}: #{e.message}")

    render json: { error: e.message }, status: :unprocessable_content
  end

  def completed
    raise ActionController::RoutingError, I18n.t('not_found') if @submitter.account.archived_at?

    unless Submitters::AuthorizedForForm.call(@submitter, current_user, request)
      return redirect_to submit_form_path(params[:submit_form_slug])
    end

    # The page a signer lands on the instant they finish, and the one they come
    # back to whenever they open their own signing link again. Reaching it
    # means holding that document's own signing slug and passing whatever 2FA
    # it carries — far more than the share link's completed page ever tells
    # anyone — so the marker is re-stamped here as well as at the completion
    # itself, and a signer who finished on a slow day still gets their own page
    # back (CompletedFormMarker).
    remember_completed_form(@submitter)
  end

  def success; end

  def delegated
    submitter_version = SubmitterVersion.find_by!(slug: params[:slug] || params[:submit_form_slug])

    @submitter = submitter_version.submitter
  end

  private

  # Archived means the account (or the document, or its template) is GONE, so
  # its signer writes stop too — the locked page `show` already renders says
  # exactly that, and until Session 7 the write behind it did not check
  # (Session 2 handoff). SUSPENDED is deliberately not here: a suspended
  # account cannot start anything new, but a signer already part-way through
  # a document always gets to finish it.
  def locked_for_writing?
    @submitter.submission.template&.archived_at? || @submitter.submission.archived_at? ||
      @submitter.account.archived_at?
  end

  def maybe_require_link_2fa
    return if Submitters::AuthorizedForForm.pass_link_2fa?(@submitter, current_user, request)

    redirect_to start_form_path(@submitter.submission.template.slug)
  end

  # Each state gets its own page here, so this asks state by state; the
  # document door asks Submitters::FormOpen.call, which is the same three
  # predicates combined. Neither can grow a state the other does not know.
  def maybe_render_locked_page
    return render :archived if Submitters::FormOpen.archived?(@submitter)
    return render :expired if @submitter.submission.expired?

    render :declined if @submitter.declined_at?
  end

  def maybe_redirect_delegated
    return if @submitter

    submitter_version = SubmitterVersion.find_by!(slug: params[:slug] || params[:submit_form_slug])

    submitter_version.submitter.submission_events.find_by!(event_type: :delegate_form)

    redirect_to submit_form_delegated_path(submitter_version.slug)
  end

  def load_submitter
    @submitter = Submitter.find_by(slug: params[:slug] || params[:submit_form_slug])
  end

  def set_embed_frame_headers
    return unless @submitter&.submission&.source_embed?

    prefs = @submitter.submission.preferences || {}
    origins = (Array(prefs['embed_origins']).presence || Array(prefs['embed_origin'])).compact_blank

    return if origins.blank?

    response.headers.delete('X-Frame-Options')
    request.content_security_policy&.frame_ancestors(:self, *origins)
  end

  def build_attachments_index(submission)
    ActiveStorage::Attachment.where(record: submission.submitters, name: :attachments)
                             .preload(:blob).index_by(&:uuid)
  end

  def embed_completion_response(submitter)
    submission = submitter.submission

    {
      submitter: Submitters::SerializeForApi.call(submitter, with_documents: false, with_urls: true, params:),
      signing_session: SigningSessions::SerializeForApi.call(submission, params:)
    }
  end
end
