# frozen_string_literal: true

class SubmissionsResendEmailController < ApplicationController
  load_and_authorize_resource :submission

  before_action do
    authorize!(:manage, :resend_all)
    authorize!(:update, @submission)
  end

  def create
    submitters = @submission.submitters.reject(&:completed_at?).select { |s| s.email.present? && !s.declined_at? }

    # Anti-abuse: a recipient emailed within the last 10 hours is skipped.
    recent_submitter_ids =
      SubmissionEvent.where(submitter_id: submitters.map(&:id),
                            event_type: 'send_email',
                            created_at: 10.hours.ago..Time.current).pluck(:submitter_id).to_set

    submitters = submitters.reject { |s| recent_submitter_ids.include?(s.id) }

    sent, refusal = resend_each(submitters)

    notice =
      if sent.empty?
        I18n.t('email_has_been_sent_already') unless refusal
      else
        I18n.t('emails_have_been_sent_to_n_recipients', count: sent.size)
      end

    redirect_back(fallback_location: submission_path(@submission), notice:, alert: refusal&.localized_message)
  end

  private

  # Each signer through Submitters::ResendGuard. A signer who has had their
  # share for the day is skipped; a refusal that would refuse everybody (a
  # paused account, the free daily cap) stops the rest. Returns
  # [the signers emailed, the last refusal or nil].
  def resend_each(submitters)
    sent = []
    refusal = nil

    submitters.each do |submitter|
      Submitters::ResendGuard.claim!(submitter)

      SendSubmitterInvitationEmailJob.perform_async('submitter_id' => submitter.id)

      submitter.sent_at ||= Time.current
      submitter.save!

      sent << submitter
    rescue Quotas::LimitReached => e
      refusal = e

      break unless e.reason == :signer_resends
    end

    [sent, refusal]
  end
end
