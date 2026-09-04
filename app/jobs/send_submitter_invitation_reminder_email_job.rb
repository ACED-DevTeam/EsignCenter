# frozen_string_literal: true

class SendSubmitterInvitationReminderEmailJob
  include Sidekiq::Job

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])
    reminder_index = params['reminder_index']

    return unless reminder_sendable?(submitter)

    # Atomically claim this reminder slot BEFORE sending. A row lock serializes concurrent
    # jobs, and recording the event before delivery means a retry (or a duplicate scheduled
    # job) finds the claim and skips — so a slot is sent at most once on success.
    claim = claim_reminder_slot(submitter, reminder_index)

    return unless claim

    deliver_reminder(submitter, claim)
  end

  private

  def deliver_reminder(submitter, claim)
    # `reminder: true` lets the mailer prefer the customer's reminder wording
    # (per-template `invitation_reminder_email_*`, or the account-level
    # submitter_invitation_reminder_email row) over the invitation wording.
    # Both are paid-only, and the mailer falls back to the invitation copy
    # whenever no reminder copy applies.
    mail = SubmitterMailer.invitation_email(submitter, reminder: true)

    Submitters::ValidateSending.call(submitter, mail)

    mail.deliver_now!
  rescue StandardError
    # Release the claim so a Sidekiq retry can re-send. This avoids permanently dropping a
    # reminder on a transient SMTP failure, while a successful send keeps the claim so
    # retries/duplicates never double-send.
    claim.destroy
    raise
  end

  def claim_reminder_slot(submitter, reminder_index)
    submitter.with_lock do
      next if reminder_already_sent?(submitter, reminder_index)

      SubmissionEvent.create!(submitter:, event_type: 'send_reminder_email',
                              data: { 'reminder_index' => reminder_index })
    end
  end

  def reminder_sendable?(submitter)
    return false if submitter.completed_at? || submitter.declined_at?
    return false if submitter.sent_at.blank? || submitter.email.blank?
    return false if submitter.preferences['send_email'] == false
    return false if submitter.submission.archived_at? || submitter.template&.archived_at?
    return false if submitter.submission.expired?
    # Reminders are paid-only: a reminder scheduled while paid does not fire after a downgrade (D43 — inert, not purged).
    return false unless Entitlements.allowed?(submitter.account, :reminders)

    if submitter.submission.source == 'invite' && !Accounts.can_send_emails?(submitter.account, on_events: true)
      return false
    end

    Accounts.can_send_invitation_emails?(submitter.account)
  end

  def reminder_already_sent?(submitter, reminder_index)
    SubmissionEvent.where(submitter_id: submitter.id, event_type: 'send_reminder_email')
                   .any? { |event| event.data['reminder_index'] == reminder_index }
  end
end
