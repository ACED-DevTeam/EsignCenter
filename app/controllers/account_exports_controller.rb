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
  rescue Accounts::Exports::EnqueueFailed => e
    # The row is already marked failed and the day's budget given back
    # (Accounts::Exports.abandon!), so the page tells the truth behind this
    # sentence and the button works again straight away.
    ErrorReport.error(e, account_id: current_account.id)

    redirect_to settings_account_export_path, alert: I18n.t('account_export_enqueue_failed')
  end

  # The link the page offers. This action is where the authorization lives —
  # is this export this account's, is it still ready, and may this person
  # export at all — and all three are asked again at the moment of the click.
  #
  # THE URL IT MINTS IS GOOD FOR TEN MINUTES, NOT SEVEN DAYS (review 2, H5).
  # The blob proxy honours a signed link without asking who is holding it, so
  # the redirect used to hand out a bearer token for a copy of the whole
  # account that stayed valid for the file's entire life: copied out of a
  # browser's history or a proxy log, it went on working after the person was
  # demoted to viewer, after they signed out, and after a support session was
  # opened on the account. Ten minutes is the life of one click; the seven
  # days remain the life of the FILE, and a second click mints a fresh link
  # after asking all three questions again.
  def download
    authorize!(:export, current_account)

    export = AccountExport.find_by(id: params[:id], account_id: current_account.id)

    return head(:not_found) if export.nil?

    unless export.downloadable?
      return redirect_to(settings_account_export_path, alert: I18n.t('account_export_download_unavailable'))
    end

    redirect_to ActiveStorage::Blob.proxy_url(export.archive.blob,
                                              expires_at: Accounts::Exports::DOWNLOAD_URL_TTL.from_now),
                allow_other_host: true
  end
end
