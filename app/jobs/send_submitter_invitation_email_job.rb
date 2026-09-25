# frozen_string_literal: true

class SendSubmitterInvitationEmailJob
  include Sidekiq::Job

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])

    return if submitter.completed_at?
    return if submitter.submission.archived_at?
    return if submitter.template&.archived_at?
    return if submitter.submission.source == 'invite' && !Accounts.can_send_emails?(submitter.account, on_events: true)

    unless Accounts.can_send_invitation_emails?(submitter.account) || next_in_signing_order?(submitter)
      ErrorReport.warning("Skip email: #{submitter.account.id}")

      return
    end

    # "First send" is the absence of a prior send_email event, NOT sent_at.blank? —
    # sent_at is pre-set at submission creation in the main flows, so it can't signal this.
    first_send = !SubmissionEvent.exists?(submitter_id: submitter.id, event_type: 'send_email')

    mail = SubmitterMailer.invitation_email(submitter)

    Submitters::ValidateSending.call(submitter, mail)

    mail.deliver_now!

    SubmissionEvent.create!(submitter:, event_type: 'send_email')

    submitter.sent_at ||= Time.current
    submitter.save!

    # Schedule reminders only on the first invitation send, not on manual re-sends.
    Submitters::ScheduleReminders.call(submitter) if first_send
  end

  private

  # A sending pause holds back new mail, but not the next signer's request on
  # a document somebody has already signed: that recipient was chosen before
  # the pause, a real signer has acted on it, and holding it would strand the
  # document the pause promises can still be completed. Resends (refused at
  # Submitters::ResendGuard) and reminders stay held.
  def next_in_signing_order?(submitter)
    submitter.submission.submitters.any? { |s| s.id != submitter.id && s.completed_at? }
  end
end
