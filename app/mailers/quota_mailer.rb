# frozen_string_literal: true

# Quota and abuse-policy mail to the active admins of a BILLING account.
# English-only copy, like SettingsMailer: these are operational notices from
# the platform, not the localized signer-facing mail. `mail_account` so the
# interceptor resolves the right outgoing server; no message metadata, so no
# EmailEvent projection (the account itself is not an emailable).
class QuotaMailer < ApplicationMailer
  def completions_warning(account)
    prepare(account)

    @used = Quotas.completions_this_month(account)
    @limit = Quotas.limits_for(account).completions_per_month

    return if @recipients.blank?

    mail(to: @recipients, subject: "You have used #{@used} of #{@limit} free document completions this month")
  end

  def paid_usage_warning(account)
    prepare(account)

    @used = Quotas.completions_this_month(account)
    @threshold = Quotas::Limits::PAID_COMPLETIONS_REVIEW_PER_SEAT * (Quotas.limits_for(account).seats || 1)

    return if @recipients.blank?

    mail(to: @recipients, subject: 'Your EsignCenter account is close to its fair-use level')
  end

  def share_link_paused(account, reason)
    prepare(account)

    @reason = reason.to_s
    @limits = Quotas.limits_for(account)

    return if @recipients.blank?

    mail(to: @recipients, subject: 'A signer could not open your form')
  end

  def sending_paused(account, reason)
    prepare(account)

    @reason = reason.to_s

    return if @recipients.blank?

    mail(to: @recipients, subject: 'Sending is paused on your EsignCenter account')
  end

  def storage_warning(account)
    prepare(account)

    @used = Quotas::Storage.human_size(Quotas::Storage.bytes_used(account))
    @limit = Quotas::Storage.human_size(Quotas::Storage.limit_bytes(account))
    @paid = Plans.key_for(account) == Plans::PAID

    return if @recipients.blank?

    mail(to: @recipients, subject: "Your EsignCenter storage is almost full (#{@used} of #{@limit})")
  end

  private

  def prepare(account)
    @current_account = account
    mail_account(account)

    @recipients = account.users.active.admins.pluck(:email)
    @resets_at = Quotas.resets_at(account)
    @usage_url = "#{root_url.delete_suffix('/')}#{Quotas::USAGE_PATH}"
    @support_email = Docuseal::SUPPORT_EMAIL
  end
end
