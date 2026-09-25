# frozen_string_literal: true

# Quota and abuse-policy mail to the active admins of a BILLING account.
# English-only copy, like SettingsMailer: these are operational notices from
# the platform, not the localized signer-facing mail. `mail_account` names the
# account: it resolves the outgoing server AND attributes the send row delivery
# tracking writes (Session 10, review 8 C3). A bounce or complaint about one of
# these is recorded against the account and — deliberately — never feeds the
# automatic sending pause, which is about the mail an account sends its
# SIGNERS (lib/sending_pause.rb).
class QuotaMailer < ApplicationMailer
  def completions_warning(account)
    return if prepare(account).blank?

    @used = Quotas.completions_this_month(account)
    @limit = Quotas.limits_for(account).completions_per_month

    mail(to: @recipients, subject: "You have used #{@used} of #{@limit} free document completions this month")
  end

  def api_usage_warning(account, percent)
    return if prepare(account).blank?

    @used = Quotas.api_completions_this_month(account)
    @limit = Quotas.limits_for(account).api_completions_per_month
    @percent = percent
    @billing_url = "#{root_url.delete_suffix('/')}#{Quotas::BILLING_PATH}"

    mail(to: @recipients, subject: "API completions: #{percent}% of your monthly allowance used")
  end

  def paid_usage_warning(account)
    return if prepare(account).blank?

    @used = Quotas.completions_this_month(account)
    @threshold = Quotas.fair_use_threshold(account)

    mail(to: @recipients, subject: 'Your EsignCenter account is close to its fair-use level')
  end

  def share_link_paused(account, reason)
    return if prepare(account).blank?

    @reason = reason.to_s
    @limits = Quotas.limits_for(account)

    mail(to: @recipients, subject: 'A signer could not open your form')
  end

  def sending_paused(account, reason)
    return if prepare(account).blank?

    @reason = reason.to_s

    mail(to: @recipients, subject: 'Sending is paused on your EsignCenter account')
  end

  # No sizes, by decision: storage is sold as "we store your documents",
  # and the cap behind it is a fair-use safeguard rather than an allowance
  # to quote. The mail says what is happening and what to do about it.
  def storage_warning(account)
    return if prepare(account).blank?

    @paid = Plans.paid_or_better?(account)

    mail(to: @recipients, subject: 'Your EsignCenter account is nearing its storage fair-use limit')
  end

  private

  # Sets the view data every one of these mails shares and returns the
  # admins it goes to. Blank means the account has no active admin, and the
  # caller sends nothing — the one refusal, written once.
  def prepare(account)
    @current_account = account
    mail_account(account)

    @resets_at = Quotas.resets_at(account)
    @usage_url = "#{root_url.delete_suffix('/')}#{Quotas::USAGE_PATH}"
    @support_email = Docuseal::SUPPORT_EMAIL
    # The upgrade line several of these notices carry, from the constants
    # billing applies, so the mail can never quote a stale price or trial.
    @price = StripeBilling::PRICE_PER_SEAT_USD
    @trial_days = StripeBilling::TRIAL_PERIOD_DAYS

    @recipients = admin_recipients(account)
  end

  # Written by the platform, not by a customer: the mail layout signs it
  # with the product's name and the support address whatever the account's
  # branding-removal setting says (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
