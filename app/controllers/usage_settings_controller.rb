# frozen_string_literal: true

# The account's own usage page (/settings/usage): what this month has used
# against every cap, honestly — over-cap numbers are shown as they are, not
# clamped — plus the storage, the seats, the UTC reset date and the sending
# pause when there is one. Everything is read live through Quotas against the
# BILLING account, so a testing or linked child sees its parent's numbers.
class UsageSettingsController < ApplicationController
  def show
    authorize!(:read, current_account)

    @billing = Plans.billing_account(current_account)
    @plan = Plans.key_for(@billing)
    @limits = Quotas.limits_for(@billing)

    @completions = Quotas.completions_this_month(@billing)
    @sends = Quotas.sends_this_month(@billing)
    @in_flight = Quotas.in_flight(@billing)
    @storage_used = Quotas::Storage.bytes_used(@billing)
    @seats_used = Accounts.users_count(@billing)

    @resets_at = Quotas.resets_at(@billing)
    @paused = SendingPause.paused?(@billing)
    @support_email = Docuseal::SUPPORT_EMAIL

    return unless @plan == Plans::PAID

    @fair_use = Quotas::Limits::PAID_COMPLETIONS_REVIEW_PER_SEAT * (@limits.seats || 1)
  end
end
