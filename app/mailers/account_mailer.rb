# frozen_string_literal: true

# Mail about the account's own existence: it is going to be deleted, it is
# about to be deleted, somebody changed their mind (D43). English-only copy
# like BillingMailer and QuotaMailer — these are operational notices from the
# platform, not localized signer mail. `mail_account` so the interceptor
# resolves the right outgoing server; no message metadata, so no EmailEvent
# projection (an account is not an emailable).
#
# Every notice here is sent as ONE MESSAGE PER PERSON, never one message
# addressed to all of them. See Broadcast below for why that is not a
# stylistic preference.
class AccountMailer < ApplicationMailer
  # One message per person.
  #
  # These mails used to be sent with `to:` set to an ARRAY of addresses, which
  # puts the whole recipient list in the To header of the copy every one of
  # them receives. For `dormant_warning` — the one notice here that goes to
  # EVERYBODY in the account, viewers and editors included — that handed every
  # member every other member's email address, which is exactly the roster the
  # app otherwise shows only to administrators (UsersController#index). An
  # intra-tenant disclosure of colleagues' addresses to people the app has
  # deliberately decided must not see them.
  #
  # The fan-out is done HERE rather than at the four call sites so that the
  # callers still read `AccountMailer.dormant_warning(account, ...)
  # .deliver_now!`, and so the two promises those callers depend on still
  # hold exactly as they did:
  #
  #   * nobody left to tell means nothing is sent — a Broadcast with no
  #     deliveries in it is a no-op, the way ActionMailer's NullMail was;
  #   * a delivery that RAISES still raises out of `deliver_now!`, which is
  #     what lets Accounts::Retention stamp "this customer was warned" only
  #     after the mail server has actually taken the message (R5). A failure
  #     part-way through the list is a failure of the whole broadcast: the
  #     warning is not stamped, and the next nightly sweep sends it again. A
  #     duplicate letter to the people already reached is much cheaper than a
  #     purge that goes ahead on a warning nobody received.
  class Broadcast
    def initialize(deliveries)
      @deliveries = deliveries
    end

    def deliver_now!(...)
      @deliveries.each { |delivery| delivery.deliver_now!(...) }
    end

    def deliver_later!(...)
      @deliveries.each { |delivery| delivery.deliver_later!(...) }
    end
  end

  class << self
    # An administrator asked us to delete the account. Says the date, what
    # still works until then, and how to change their mind.
    def deletion_scheduled(account)
      broadcast(account) { |to| deletion_scheduled_to(account, to) }
    end

    # A week to go. The date was in the first email; this is the last chance
    # to press the button.
    def deletion_reminder(account)
      broadcast(account) { |to| deletion_reminder_to(account, to) }
    end

    def deletion_cancelled(account)
      broadcast(account) { |to| deletion_cancelled_to(account, to) }
    end

    # Nobody has signed in for nearly a year. Goes to EVERY person in the
    # account, not only the admins: the whole problem with a dormant account
    # is that the person who set it up may have left, and the one who still
    # reads their mail is the one who needs to hear this. Which is also why
    # this one may never carry the roster with it — see Broadcast.
    def dormant_warning(account, days_left:, purge_at:)
      broadcast(account, everyone: true) do |to|
        dormant_warning_to(account, to, days_left:, purge_at:)
      end
    end

    private

    # The one refusal, written once (QuotaMailer#prepare): blank means there
    # is nobody left to tell, and the caller sends nothing.
    def broadcast(account, everyone: false, &build)
      Broadcast.new(recipients_for(account, everyone:).map(&build))
    end

    def recipients_for(account, everyone: false)
      (everyone ? account.users.active : account.users.active.admins).pluck(:email).compact_blank.uniq
    end
  end

  def deletion_scheduled_to(account, to)
    return if prepare(account, to).blank?

    mail(to:, subject: "Your EsignCenter account is scheduled for deletion on #{@purge_date}")
  end

  def deletion_reminder_to(account, to)
    return if prepare(account, to).blank?

    @days_left = Accounts::Retention::DELETION_REMINDER_DAYS

    mail(to:, subject: "Your EsignCenter account is deleted on #{@purge_date}")
  end

  def deletion_cancelled_to(account, to)
    return if prepare(account, to).blank?

    mail(to:, subject: 'Your EsignCenter account will not be deleted')
  end

  def dormant_warning_to(account, to, days_left:, purge_at:)
    return if prepare(account, to).blank?

    @days_left = days_left
    @purge_date = format_date(purge_at)

    mail(to:, subject: "Your unused EsignCenter account will be deleted in #{days_left} days")
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

  # Sets the view data every one of these mails shares and returns the one
  # address it goes to. Blank means there is nobody to write to and the
  # message is not built at all.
  def prepare(account, recipient)
    @current_account = account
    mail_account(account)

    @purge_date = format_date(account.purge_scheduled_for)
    @window_days = Accounts::Deletion::WINDOW_DAYS
    @account_url = "#{root_url.delete_suffix('/')}/settings/account"
    @templates_url = "#{root_url.delete_suffix('/')}/templates"
    @support_email = Docuseal::SUPPORT_EMAIL

    recipient.presence
  end
end
