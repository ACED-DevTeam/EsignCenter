# frozen_string_literal: true

# Quota and abuse-policy mail to the active admins of a BILLING account.
# English-only copy, like SettingsMailer: these are operational notices from
# the platform, not the localized signer-facing mail. `mail_account` so the
# interceptor resolves the right outgoing server; no message metadata, so no
# EmailEvent projection (the account itself is not an emailable).
class QuotaMailer < ApplicationMailer
  def completions_warning(account)
    return if prepare(account).blank?

    @used = Quotas.completions_this_month(account)
    @limit = Quotas.limits_for(account).completions_per_month

    mail(to: @recipients, subject: "You have used #{@used} of #{@limit} free document completions this month")
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

  def storage_warning(account)
    return if prepare(account).blank?

    @used = Quotas::Storage.human_size(Quotas::Storage.bytes_used(account))
    @limit = Quotas::Storage.human_size(Quotas::Storage.limit_bytes(account))
    @paid = Plans.key_for(account) == Plans::PAID

    mail(to: @recipients, subject: "Your EsignCenter storage is almost full (#{@used} of #{@limit})")
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

    @recipients = account.users.active.admins.pluck(:email)
  end

  # Written by the platform, not by a customer: the mail layout signs it
  # with the product's name and the support address whatever the account's
  # branding-removal setting says (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
