# frozen_string_literal: true

# Dunning mail to the active admins of a BILLING account: the card failed,
# here is what happens and when, and here is the one page that fixes it.
# English-only copy like QuotaMailer and SettingsMailer — these are
# operational notices from the platform, not localized signer mail.
# `mail_account` so the interceptor resolves the right outgoing server; no
# message metadata, so no EmailEvent projection (an account is not an
# emailable).
class BillingMailer < ApplicationMailer
  # One reminder inside the grace period. `day` is how many days into it we
  # are (BillingLifecycle::DUNNING_DAYS) and `suspends_on` is the date the
  # account stops being able to send — every one of these says both.
  def payment_failed(account, day:, suspends_on: nil)
    return if prepare(account).blank?

    @day = day
    @suspends_on = suspends_on
    @last_warning = day == BillingLifecycle::DUNNING_DAYS.last

    mail(to: @recipients, subject: subject_for_day(day))
  end

  def suspended(account)
    return if prepare(account).blank?

    mail(to: @recipients, subject: 'Your EsignCenter account is suspended')
  end

  def payment_recovered(account)
    return if prepare(account).blank?

    mail(to: @recipients, subject: 'Your EsignCenter payment went through')
  end

  # The plan no longer has room for everyone (D43). Nobody was deleted: one
  # admin keeps full access, the rest became read-only, and this mail says who
  # and where to change it.
  def seats_reduced(account, kept:, seats:)
    return if prepare(account).blank?

    @kept_name = kept&.full_name.presence || kept&.email
    @seats = seats
    @users_url = "#{root_url.delete_suffix('/')}/settings/users"

    mail(to: @recipients, subject: 'Your EsignCenter plan now has fewer seats')
  end

  private

  # The first email is news; the last one is a deadline. Saying the same
  # thing four times teaches people to ignore it.
  def subject_for_day(day)
    return 'We could not take your EsignCenter payment' if day.zero?
    return 'Last reminder: your EsignCenter account is suspended tomorrow' if @last_warning

    'Your EsignCenter payment is still outstanding'
  end

  # Sets the view data every one of these mails shares and returns the admins
  # it goes to. Blank means the account has no active admin, and the caller
  # sends nothing — the one refusal, written once (QuotaMailer#prepare).
  def prepare(account)
    @current_account = account
    mail_account(account)

    @grace_days = BillingLifecycle::PAST_DUE_GRACE_DAYS
    @billing_url = "#{root_url.delete_suffix('/')}/settings/billing"
    @support_email = Docuseal::SUPPORT_EMAIL

    @recipients = account.users.active.admins.pluck(:email)
  end
end
