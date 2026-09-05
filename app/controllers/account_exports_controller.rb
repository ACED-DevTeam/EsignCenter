# frozen_string_literal: true

# The account's own export page (/settings/export): ask for a zip of
# everything, watch it being built, download it while the link lasts
# (Session 8 phase D).
#
# Authorized on `:export` of the account, which is an administrator's
# ability and one of the few the read-only layer deliberately KEEPS
# (lib/ability.rb): a suspended account and an account that has asked to be
# deleted must both still be able to take their data with them — that is the
# whole promise the 90-day window is built on. Support impersonation is the
# other side of that coin: an operator looking at a customer's account may
# never pull the customer's entire document store out of it, so this
# controller is `:forbidden` in SupportImpersonation::CLASSIFICATION and the
# ability layer refuses `:export` in both modes.
class AccountExportsController < ApplicationController
  def show
    authorize!(:export, current_account)

    @export = Accounts::Exports.latest(current_account)
    @remaining_today = Accounts::Exports.remaining_today(current_account)
    @limit_per_day = Accounts::Exports::MAX_PER_DAY
    @ttl_days = Accounts::Exports::TTL.in_days.to_i
  end

  def create
    authorize!(:export, current_account)

    export = Accounts::Exports.request!(current_account, requested_by: current_user)

    redirect_to settings_account_export_path,
                notice: export.in_progress? ? I18n.t('account_export_started') : I18n.t('account_export_reused')
  rescue Accounts::Exports::LimitReached => e
    redirect_to settings_account_export_path, alert: I18n.t('account_export_limit_reached', limit: e.limit)
  end

  # The link the page offers. Signed and expiring is not enough on its own —
  # a signed URL cannot be withdrawn — so the three questions are asked again
  # here, at the moment of the click: is this export this account's, is it
  # still ready, and may this person export at all.
  def download
    authorize!(:export, current_account)

    export = AccountExport.find_by(id: params[:id], account_id: current_account.id)

    return head(:not_found) if export.nil?

    unless export.downloadable?
      return redirect_to(settings_account_export_path, alert: I18n.t('account_export_download_unavailable'))
    end

    redirect_to ActiveStorage::Blob.proxy_url(export.archive.blob, expires_at: export.expires_at),
                allow_other_host: true
  end
end
