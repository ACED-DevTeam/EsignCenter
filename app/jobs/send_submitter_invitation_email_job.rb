# frozen_string_literal: true

class SendSubmitterInvitationEmailJob
  include Sidekiq::Job

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])

    return if submitter.completed_at?
    return if submitter.submission.archived_at?
    return if submitter.template&.archived_at?
    return if submitter.submission.source == 'invite' && !Accounts.can_send_emails?(submitter.account, on_events: true)

    unless Accounts.can_send_invitation_emails?(submitter.account)
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
end
