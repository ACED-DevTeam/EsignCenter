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
  #
  # `late` is the one case where the deadline is already behind us: a sweep
  # that missed the day-13 tick sends this letter in the same breath as the
  # suspension itself, so the letter says the freeze HAS happened instead of
  # promising it for a date that has been and gone.
  def payment_failed(account, day:, suspends_on: nil, late: false)
    return if prepare(account).blank?

    @day = day
    @suspends_on = suspends_on
    @late = late
    @last_warning = day == BillingLifecycle::DUNNING_DAYS.last

    mail(to: @recipients, subject: subject_for_day(day))
  end

  def suspended(account)
    return if prepare(account).blank?

    mail(to: @recipients, subject: 'Your EsignCenter account is suspended')
  end

  # `lifted` is whether THIS recovery actually unfroze the account, and the
  # letter says which of the two happened rather than hedging with "if the
  # account was suspended" (checkpoint 7, B5). The caller knows the answer —
  # it is the transition `AccountStates.lift_suspension!` just returned — so
  # there is no reason to make the customer work it out.
  #
  # It is a fact about THIS recovery and nothing else (checkpoint 7, Q3). An
  # account that was frozen for a missed payment three months ago and paid on
  # time today must not be told "nothing was ever frozen": the letter says
  # only that it was not frozen this time.
  def payment_recovered(account, lifted: false)
    return if prepare(account).blank?

    @lifted = lifted

    mail(to: @recipients, subject: 'Your EsignCenter payment went through')
  end

  # The plan no longer has room for everyone (D43). Nobody was deleted: one
  # admin keeps full access, the rest became read-only, and this mail says who
  # and where to change it.
  def seats_reduced(account, kept:, seats:, revoked: 0)
    return if prepare(account).blank?

    @kept_name = kept&.full_name.presence || kept&.email
    @seats = seats
    # Invitations that were holding a seat the plan no longer has: they are
    # cancelled rather than left to be accepted into a full account, and the
    # admin has to hear about it or they will wonder where they went.
    @revoked = revoked.to_i
    @users_url = "#{root_url.delete_suffix('/')}/settings/users"

    mail(to: @recipients, subject: 'Your EsignCenter plan now has fewer seats')
  end

  private

  # The first email is news; the last one is a deadline. Saying the same
  # thing four times teaches people to ignore it.
  def subject_for_day(day)
    return 'We could not take your EsignCenter payment' if day.zero?
    # The catch-up copy of the last warning: the suspension happened today,
    # so promising it for tomorrow would be the one thing the subject line
    # must not do.
    return 'Last reminder: your EsignCenter payment is overdue' if @late
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

    @recipients = account.users.active.admins.pluck(:email)
  end

  # Written by the platform, not by a customer: the mail layout signs it
  # with the product's name and the support address whatever the account's
  # branding-removal setting says (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
