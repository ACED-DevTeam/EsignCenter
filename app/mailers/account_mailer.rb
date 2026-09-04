# frozen_string_literal: true

# Mail about the account's own existence: it is going to be deleted, it is
# about to be deleted, somebody changed their mind (D43). English-only copy
# like BillingMailer and QuotaMailer — these are operational notices from the
# platform, not localized signer mail. `mail_account` so the interceptor
# resolves the right outgoing server; no message metadata, so no EmailEvent
# projection (an account is not an emailable).
class AccountMailer < ApplicationMailer
  # An administrator asked us to delete the account. Says the date, what still
  # works until then, and how to change their mind.
  def deletion_scheduled(account)
    return if prepare(account).blank?

    mail(to: @recipients, subject: "Your EsignCenter account is scheduled for deletion on #{@purge_date}")
  end

  # A week to go. The date was in the first email; this is the last chance to
  # press the button.
  def deletion_reminder(account)
    return if prepare(account).blank?

    @days_left = Accounts::Retention::DELETION_REMINDER_DAYS

    mail(to: @recipients, subject: "Your EsignCenter account is deleted on #{@purge_date}")
  end

  def deletion_cancelled(account)
    return if prepare(account).blank?

    mail(to: @recipients, subject: 'Your EsignCenter account will not be deleted')
  end

  # Nobody has signed in for nearly a year. Goes to EVERY person in the
  # account, not only the admins: the whole problem with a dormant account is
  # that the person who set it up may have left, and the one who still reads
  # their mail is the one who needs to hear this.
  def dormant_warning(account, days_left:, purge_at:)
    return if prepare(account, everyone: true).blank?

    @days_left = days_left
    @purge_date = format_date(purge_at)

    mail(to: @recipients, subject: "Your unused EsignCenter account will be deleted in #{days_left} days")
  end

  # The second way to confirm a deletion: a code to the administrator's own
  # address, so somebody who signs in with Google — and therefore has no
  # password they know — can still prove it is them (review batch 2, K9).
  # Goes to ONE person, the one who asked, and never to "every admin": it is
  # a credential, not an announcement.
  # The code goes in the BODY and never in the subject (review batch 2, P5):
  # a subject line is the part that shows on a lock screen, in a notification
  # bar and in every mail client's list view, so a code there is readable by
  # anyone standing near the phone — and by anything that indexes or logs
  # subjects.
  def deletion_code(user, code:)
    @current_account = user.account
    mail_account(user.account)

    @code = code
    @minutes = Accounts::DeletionCodes::TTL.in_minutes.to_i
    @support_email = Docuseal::SUPPORT_EMAIL

    mail(to: user.email, subject: 'Your EsignCenter account deletion code')
  end

  private

  def format_date(time)
    Accounts::Deletion.format_date(time)
  end

  # Sets the view data every one of these mails shares and returns the people
  # it goes to. Blank means there is nobody left to tell, and the caller sends
  # nothing — the one refusal, written once (QuotaMailer#prepare).
  def prepare(account, everyone: false)
    @current_account = account
    mail_account(account)

    @purge_date = format_date(account.purge_scheduled_for)
    @window_days = Accounts::Deletion::WINDOW_DAYS
    @account_url = "#{root_url.delete_suffix('/')}/settings/account"
    @templates_url = "#{root_url.delete_suffix('/')}/templates"
    @support_email = Docuseal::SUPPORT_EMAIL

    @recipients = (everyone ? account.users.active : account.users.active.admins).pluck(:email).compact_blank
  end
end
