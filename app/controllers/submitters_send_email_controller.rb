# frozen_string_literal: true

class SubmittersSendEmailController < ApplicationController
  load_and_authorize_resource :submitter

  def create
    authorize!(:update, @submitter)

    # Anti-abuse: one invitation email per recipient per 10 hours.
    if SubmissionEvent.exists?(submitter: @submitter,
                               event_type: 'send_email',
                               created_at: 10.hours.ago..Time.current)
      ErrorReport.warning("Already sent: #{@submitter.id}")

      return redirect_back(fallback_location: submission_path(@submitter.submission),
                           alert: I18n.t('email_has_been_sent_already'))
    end

    # Paused sending, the per-signer day and the free daily cap
    # (Submitters::ResendGuard).
    Submitters::ResendGuard.claim!(@submitter)

    SendSubmitterInvitationEmailJob.perform_async('submitter_id' => @submitter.id)

    @submitter.sent_at ||= Time.current
    @submitter.save!

    redirect_back(fallback_location: submission_path(@submitter.submission), notice: I18n.t('email_has_been_sent'))
  rescue Quotas::LimitReached => e
    redirect_back(fallback_location: submission_path(@submitter.submission), alert: e.localized_message)
  end
end
