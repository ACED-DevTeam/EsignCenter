# frozen_string_literal: true

class StartFormController < ApplicationController
  layout 'form'

  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_browser_locale, only: %i[show update completed]
  before_action :load_resubmit_submitter, only: :update
  before_action :load_template
  before_action :refuse_email_2fa_shared_link!, except: :show
  before_action :refuse_unready_documents!, only: %i[show update]
  before_action :authorize_start!, only: :update

  COOKIES_TTL = 12.hours
  COOKIES_DEFAULTS = { httponly: true, secure: Rails.env.production? }.freeze

  def show
    if @template.shared_link?
      # A shared template that also requires email 2FA cannot be opened by
      # link: explain that instead of a form that would fail. Non-shared
      # templates keep the owner-private / anonymous-404 answers below, so
      # the page never confirms a private template's existence.
      return render :email_verification_required if @template.preferences['require_email_2fa']

      # A capped or paused account's link is closed for now: computed on
      # every request, so it reopens by itself at month rollover. The owner
      # is told once per month that a signer was turned away.
      if !@template.archived_at? && (reason = Quotas.share_link_paused?(@template.account))
        Quotas.notify_share_link_pause!(@template.account, reason) unless sender_viewing?

        return render_paused(reason)
      end

      @submitter = @template.submissions.new(account_id: @template.account_id)
                            .submitters.new(account_id: @template.account_id,
                                            uuid: (filter_undefined_submitters(@template).first ||
                                                  @template.submitters.first)['uuid'])
      render :email_verification if params[:email_verification]
    else
      ErrorReport.warning("Not shared template: #{@template.id}")

      return render :private if current_user && current_ability.can?(:read, @template)

      raise ActionController::RoutingError, I18n.t('not_found')
    end
  end

  def update
    @submitter = find_or_initialize_submitter(@template, submitter_params)

    if @submitter.completed_at?
      redirect_to start_form_completed_path(@template.slug, submitter_params.compact_blank)
    else
      if filter_undefined_submitters(@template).size > 1 && @submitter.new_record?
        @error_message = multiple_submitters_error_message

        return render :show, status: :unprocessable_content
      end

      if (is_new_record = @submitter.new_record?)
        # A closed link takes no new submission: refused here, before the
        # email-2FA branch below could send a code for a form that cannot be
        # started. The locked re-check in save_submitter still decides the
        # race; a pending submitter found above is not a creation.
        Quotas.assert_can_create_submissions!(@template.account)

        assign_submission_attributes(@submitter, @template)

        Submissions::AssignDefinedSubmitters.call(@submitter.submission)
      else
        @submitter.assign_attributes(ip: request.remote_ip, ua: request.user_agent)
      end

      if @template.preferences['shared_link_2fa'] == true
        handle_require_2fa(@submitter, is_new_record:)
      elsif @submitter.errors.blank? && save_submitter(@submitter, is_new_record:)
        enqueue_new_submitter_jobs(@submitter) if is_new_record

        redirect_to submit_form_path(@submitter.slug)
      else
        render :show, status: :unprocessable_content
      end
    end
  rescue Quotas::LimitReached => e
    return render json: { error: e.localized_message }, status: :unprocessable_content unless request.format.html?

    render_paused(e.reason, status: :unprocessable_content)
  end

  def completed
    return redirect_to start_form_path(@template.slug) if !@template.shared_link? || @template.archived_at?

    submitter_params = params.permit(:name, :email, :phone).tap do |attrs|
      attrs[:email] = Submissions.normalize_email(attrs[:email])
    end

    required_fields = @template.preferences.fetch('link_form_fields', ['email'])

    required_params = required_fields.index_with { |key| submitter_params[key] }

    raise ActionController::RoutingError, I18n.t('not_found') if required_params.any? { |_, v| v.blank? } ||
                                                                 required_params.except('name').compact_blank.blank?

    @submitter = Submitter.where(submission: @template.submissions)
                          .where.not(completed_at: nil)
                          .find_by!(required_params.except('name'))
  end

  private

  # A NEW submitter on a share link is a new Submission, so it is checked and
  # saved under the account's creation lock (and a paid account's velocity
  # signals recorded there); a pending submitter found by
  # find_or_initialize_submitter already exists and is not a creation.
  def save_submitter(submitter, is_new_record:)
    return submitter.save unless is_new_record

    Quotas.with_creation_lock(@template.account) do
      Quotas.assert_can_create_submissions!(@template.account)

      saved = submitter.save

      Quotas.record_paid_signals(@template.account) if saved

      saved
    end
  end

  # The signer sees "not accepting responses"; the account's own signed-in
  # user (selfsign, or opening their own link) sees what happened and where
  # to go, since only they can act on it.
  def render_paused(reason, status: :ok)
    @quota_reason = reason

    if sender_viewing?
      @quota_sender_view = true
      @quota_message = Quotas.pause_message(@template.account, reason)
    end

    render :paused, status:
  end

  def sender_viewing?
    current_user.present? && current_user.account_id == @template.account_id
  end

  def enqueue_new_submitter_jobs(submitter)
    WebhookUrls.enqueue_events(submitter.submission, 'submission.created')

    SearchEntries.enqueue_reindex(submitter)

    return unless submitter.submission.expire_at?

    ProcessSubmissionExpiredJob.perform_at(submitter.submission.expire_at, 'submission_id' => submitter.submission_id)
  end

  # The share link of an email-2FA template is closed to anonymous writes as
  # well as to the page (show explains it): a PUT with a self-supplied email
  # would otherwise create a link submission nobody invited. Refused before
  # any submitter is looked up or built; the anonymous completed lookup and a
  # resubmit of a link-source submission go through the same door. Two flows
  # are not the anonymous link start and pass: the sender who can manage the
  # template (e.g. "Sign it yourself" / selfsign), and a resubmit by the holder
  # of an invited submitter's slug - that slug is the emailed invitation, so a
  # non-link source is proof of it. Non-shared templates keep
  # authorize_start!'s answers.
  def refuse_email_2fa_shared_link!
    return unless @template.shared_link? && @template.preferences['require_email_2fa']
    return if current_user && current_ability.can?(:update, @template)
    return if @resubmit_submitter && !@resubmit_submitter.submission.source_link?
    return head :forbidden unless request.format.html?

    render :email_verification_required, status: :forbidden
  end

  # A template with a Word document still converting (or failed) has no PDF
  # to sign yet: the shared link, the sender's own "sign yourself" start and
  # a signer's Resubmit (the holder of a completed submitter's slug, whom
  # authorize_start! admits on a private template) get an explanation
  # instead of a form. Only for templates the visitor may open anyway, so a
  # private template's existence is not confirmed.
  def refuse_unready_documents!
    status = Templates.documents_status(@template)

    return if status.nil?
    return unless @resubmit_submitter || @template.shared_link? ||
                  (current_user && current_ability.can?(:update, @template))
    return head :unprocessable_content unless request.format.html?

    @documents_not_ready = Templates::DocumentsNotReady.new(status)

    render :documents_not_ready, status: :unprocessable_content
  end

  def load_resubmit_submitter
    @resubmit_submitter =
      if params[:resubmit].present? && !params[:resubmit].in?([true, 'true'])
        submitter = Submitter.find_by(slug: params[:resubmit])

        submitter if submitter && can_resubmit?(submitter)
      end
  end

  def can_resubmit?(submitter)
    submitter.account.account_configs.find_or_initialize_by(key: AccountConfig::ALLOW_TO_RESUBMIT).value != false
  end

  def authorize_start!
    return redirect_to submit_form_path(@resubmit_submitter.slug) if @resubmit_submitter && @template.archived_at?
    return redirect_to start_form_path(@template.slug) if @template.archived_at?

    return if @resubmit_submitter
    return if @template.shared_link? || (current_user && current_ability.can?(:read, @template))

    ErrorReport.warning("Not shared template: #{@template.id}")

    redirect_to start_form_path(@template.slug)
  end

  def find_or_initialize_submitter(template, submitter_params)
    required_fields = template.preferences.fetch('link_form_fields', ['email'])

    required_params = required_fields.index_with { |key| submitter_params[key] }

    find_params = required_params.except('name')

    submitter = Submitter.new if find_params.compact_blank.blank?

    submitter ||=
      Submitter
      .where(submission: template.submissions.where(expire_at: Time.current..)
                                 .or(template.submissions.where(expire_at: nil)).where(archived_at: nil))
      .order(id: :desc)
      .where(declined_at: nil)
      .where(external_id: nil)
      .where(template.preferences['shared_link_2fa'] == true ? {} : { ip: [nil, request.remote_ip] })
      .then { |rel| params[:resubmit].present? || params[:selfsign].present? ? rel.where(completed_at: nil) : rel }
      .find_or_initialize_by(find_params)

    submitter.name = required_params['name'] if submitter.new_record?

    unless @resubmit_submitter
      required_params.each do |key, value|
        submitter.errors.add(key.to_sym, :blank) if value.blank?
      end
    end

    submitter
  end

  def assign_submission_attributes(submitter, template)
    submitter.assign_attributes(
      uuid: (filter_undefined_submitters(template).first || @template.submitters.first)['uuid'],
      ip: request.remote_ip,
      ua: request.user_agent,
      values: @resubmit_submitter&.preferences&.fetch('default_values', nil) || {},
      preferences: @resubmit_submitter&.preferences.presence || { 'send_email' => true },
      metadata: @resubmit_submitter&.metadata.presence || {}
    )

    submitter.assign_attributes(@resubmit_submitter.slice(:name, :email, :phone)) if @resubmit_submitter

    if submitter.values.present?
      @resubmit_submitter.attachments.each do |attachment|
        submitter.attachments << attachment.dup if submitter.values.value?(attachment.uuid)
      end
    end

    submitter.submission ||= Submission.new(template:,
                                            account_id: template.account_id,
                                            template_submitters: template.submitters,
                                            expire_at: Templates.build_default_expire_at(template),
                                            submitters: [submitter],
                                            source: :link)

    Submissions::CreateFromSubmitters.maybe_set_dynamic_documents(submitter.submission)

    submitter.account_id = submitter.submission.account_id

    submitter
  end

  def filter_undefined_submitters(template)
    Templates.filter_undefined_submitters(template.submitters)
  end

  def submitter_params
    return { 'email' => current_user.email, 'name' => current_user.full_name } if params[:selfsign]
    return @resubmit_submitter.slice(:name, :phone, :email) if @resubmit_submitter.present?

    params.require(:submitter).permit(:email, :phone, :name).tap do |attrs|
      attrs[:email] = Submissions.normalize_email(attrs[:email])
    end
  end

  def load_template
    @template =
      if @resubmit_submitter
        @resubmit_submitter.template
      else
        Template.find_by!(slug: params[:slug] || params[:start_form_slug])
      end
  end

  def multiple_submitters_error_message
    if current_user&.account_id == @template.account_id
      helpers.t('this_submission_has_multiple_signers_which_prevents_the_use_of_a_sharing_link_html')
    else
      I18n.t('not_found')
    end
  end

  def handle_require_2fa(submitter, is_new_record:)
    return render :show, status: :unprocessable_content if submitter.errors.present?

    is_otp_verified = Submitters.verify_link_otp!(params[:one_time_code], submitter)

    if cookies.encrypted[:email_2fa_slug] == submitter.slug || is_otp_verified
      if save_submitter(submitter, is_new_record:)
        enqueue_new_submitter_jobs(submitter) if is_new_record

        if is_otp_verified
          SubmissionEvents.create_with_tracking_data(submitter, 'email_verified', request)

          cookies.encrypted[:email_2fa_slug] =
            { value: submitter.slug, expires: COOKIES_TTL.from_now, **COOKIES_DEFAULTS }
        end

        redirect_to submit_form_path(submitter.slug)
      else
        render :show, status: :unprocessable_content
      end
    else
      Submitters.send_shared_link_email_verification_code(submitter, request:)

      render :email_verification
    end
  rescue Submitters::UnableToSendCode, Submitters::InvalidOtp => e
    redirect_to start_form_path(submitter.submission.template.slug,
                                params: submitter_params.merge(email_verification: true)),
                alert: e.message
  rescue RateLimit::LimitApproached
    redirect_to start_form_path(submitter.submission.template.slug,
                                params: submitter_params.merge(email_verification: true)),
                alert: I18n.t(:too_many_attempts)
  end
end
