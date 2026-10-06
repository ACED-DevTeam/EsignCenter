# frozen_string_literal: true

class SubmittersController < ApplicationController
  load_and_authorize_resource :submitter, only: %i[edit update]

  def edit
    @submitter_email_message =
      if @submitter.preferences['email_message_uuid'].present?
        @submitter.account.email_messages.find_by(uuid: @submitter.preferences['email_message_uuid'])
      end
  end

  def update
    submission = @submitter.submission

    if @submitter.submission_events.exists?(event_type: 'start_form') || submission.archived_at? || submission.expired?
      return redirect_back fallback_location: submission_path(submission), alert: I18n.t('submitter_cannot_be_updated')
    end

    if submitter_params.values.all?(&:blank?)
      return redirect_back fallback_location: submission_path(submission),
                           alert: I18n.t('at_least_one_field_must_be_filled')
    end

    if params[:is_custom_message] != '1'
      params.delete(:subject)
      params.delete(:body)
    end

    assign_email_message(@submitter)
    assign_submitter_attrs(@submitter, submitter_params)

    resend = resend_decision(@submitter, email_changed: rotate_slug_on_new_address(@submitter))

    # Decided before anything is written: a refused resend changes nothing.
    Submitters::ResendGuard.claim!(@submitter) if resend == :send

    if @submitter.save
      SendSubmitterInvitationEmailJob.perform_async('submitter_id' => @submitter.id) if resend == :send

      SearchEntries.enqueue_reindex(@submitter)

      # The one silent throttle in the product says so: a "saved" that
      # quietly dropped the resend looked like a lost email.
      notice = resend == :throttled ? I18n.t('invitation_already_sent_recently') : I18n.t('changes_have_been_saved')

      redirect_back fallback_location: submission_path(submission), notice:
    else
      redirect_back fallback_location: submission_path(submission), alert: I18n.t('unable_to_save')
    end
  rescue Quotas::LimitReached => e
    redirect_back fallback_location: submission_path(submission), alert: e.localized_message
  end

  private

  def assign_email_message(submitter)
    submitter_preferences = Submitters.normalize_preferences(submitter.account, current_user, params)

    return unless submitter_preferences.key?('email_message_uuid')

    submitter.preferences['email_message_uuid'] = submitter_preferences['email_message_uuid']
  end

  # A new address revokes the old signing link, exactly as the API does: the
  # slug is the credential in the URL, and the mailbox that was wrong must
  # lose access. Returns whether the address changed.
  def rotate_slug_on_new_address(submitter)
    return false unless submitter.will_save_change_to_email?

    submitter.slug = SecureRandom.base58(14)

    true
  end

  # SMS is a hidden feature (no plan has it): `Submitters.normalize_preferences`
  # above already refuses `send_sms`, so only the e-mail resend exists here.
  # Returns :send, :throttled, or nil when no resend was asked for.
  #
  # The same address emailed within 4 hours is quietly not repeated. That rule
  # is keyed on this SIGNER, and a changed address is not a way round it but a
  # correction, which goes out — through Submitters::ResendGuard, whose
  # per-signer daily count ignores the address entirely.
  def resend_decision(submitter, email_changed:)
    return unless params[:send_email] == '1' && Submitters.signature_request_sendable?(submitter)
    return :send if email_changed

    is_sent_recently = EmailEvent.exists?(tag: 'submitter_invitation',
                                          emailable: submitter,
                                          event_type: 'send',
                                          created_at: 4.hours.ago..Time.current)

    is_sent_recently ? :throttled : :send
  end

  def assign_submitter_attrs(submitter, attrs)
    submitter.phone = attrs[:phone].to_s.gsub(/[^0-9+]/, '') if attrs.key?(:phone)

    submitter.email = Submissions.normalize_email(attrs[:email]) if attrs.key?(:email)

    submitter.name = attrs[:name] if attrs.key?(:name)

    submitter
  end

  def submitter_params
    params.require(:submitter).permit(:email, :name, :phone).transform_values(&:strip)
  end
end
