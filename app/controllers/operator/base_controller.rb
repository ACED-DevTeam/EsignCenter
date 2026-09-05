# frozen_string_literal: true

module Operator
  # Every page of the platform-operator console hangs off this.
  #
  # AUTHORIZATION. ApplicationController turns CanCan's `check_authorization`
  # on for the whole app, so a controller that authorizes nothing normally
  # fails loudly — which is what we want everywhere a CUSTOMER acts inside
  # their own account. This surface is the one place where that is the wrong
  # question: there is no account for the operator to be authorized against.
  # The operator reads and writes ACROSS tenants by definition, and the gate
  # that decides whether that is allowed is `require_operator_access!` — a
  # platform-operator flag plus enrolled 2FA, answered with a 404 for
  # everybody else so the surface does not exist for them. So the check is
  # skipped deliberately and the gate is prepended: prepended, because a
  # visitor who is not signed in must meet the 404 BEFORE Devise can answer
  # with a redirect to sign-in, which would confirm the page is there.
  #
  # `refuse_while_impersonating` is not needed here and is deliberately
  # absent: operator access is a property of the Warden user (`true_user`),
  # so test mode neither grants nor removes it, and every page below reads
  # the account the operator PICKED rather than `current_account`.
  class BaseController < ApplicationController
    # A change the console will not make, and the plain-English sentence
    # saying why. Never a 500 and never a silent no-op: the page comes back
    # with the reason on it and a 422, because nothing was changed.
    class Refused < StandardError; end

    # Every state action takes a reason, and it has to be a sentence rather
    # than a keystroke: this row is what a person reads in six months when
    # they ask why an account was frozen.
    MINIMUM_REASON_LENGTH = 5

    skip_authorization_check

    prepend_before_action :require_operator_access!

    helper_method :open_abuse_flag_count

    private

    # The badge on the console's Abuse tab, on every page of the console: how
    # many flags are open and waiting for a person. One count, memoised per
    # request, so the navigation is the same everywhere it is rendered.
    def open_abuse_flag_count
      @open_abuse_flag_count ||= AbuseFlag.open.count
    end

    # The console never uses `current_account` for data. Every query names the
    # account the operator asked for, and this is the one place it is looked
    # up — including the two whole-tenant rules the whole console shares:
    # a testing child is not an account of its own (it is a corner of its
    # parent, and it is the parent's page that shows it), and a purged
    # tombstone is still worth looking at.
    def find_account!
      Account.where.not(id: Account.testing_child_ids).find(params[:id])
    end

    # The accounts the console lists and acts on: everything except the
    # testing children.
    def console_accounts
      Account.where.not(id: Account.testing_child_ids)
    end

    # The two accounts nothing in this phase may change: the operator's own
    # account (changing it is how an operator locks themselves out of the
    # platform) and the internal accounts that ARE the platform. Both stay
    # fully readable — an operator must be able to look at them.
    def assert_actionable!(account)
      return true if account.customer?

      raise Refused, I18n.t('operator_refused_platform_account', kind: account.account_kind)
    end

    def required_reason
      reason = params[:reason].to_s.strip

      raise Refused, I18n.t('operator_refused_reason_required', count: MINIMUM_REASON_LENGTH) \
        if reason.length < MINIMUM_REASON_LENGTH

      reason
    end

    # Every console mutation's audit row, written from INSIDE the transaction
    # that makes the change — so a rolled-back change takes its line with it,
    # and a change that lands cannot land without one. One writer, because a
    # tab with its own copy of this is a tab that can quietly stop naming the
    # operator, or the account, or where the request came from.
    #
    # `account:` defaults to the account the page loaded, which is what the
    # per-account tab acts on; the tabs that work across accounts (abuse,
    # billing) name theirs on every call.
    def record!(action, reason:, account: @account, subject: nil, details: {})
      OperatorEvents.record!(operator: true_user, action:, account:, subject:, reason:, details:, request:)
    end

    # A refusal is answered by the SAME page, with the reason on it, and a 422
    # because nothing was changed: the transaction the refusal was raised
    # inside has already rolled back. Never a 500 and never a silent no-op.
    # The block is how that particular tab loads itself again.
    def refused_page(error, template)
      flash.now[:alert] = error.message

      yield

      render template, status: :unprocessable_content
    end

    # Lifting the automatic abuse pause, offered from two places — the account
    # page and the abuse queue — and therefore written once. The three guards
    # are the door: an internal account is readable but never actionable, and
    # an account that is not paused has nothing to lift. The resume and its
    # audit row are one transaction; SendingPause.resume! resolves the open
    # complaint / bounce_rate flags under the same lock.
    def resume_sending!(account, reason:, details: {})
      assert_actionable!(account)

      paused_at, = SendingPause.state(account)

      raise Refused, I18n.t('operator_refused_not_paused') if paused_at.blank?

      ApplicationRecord.transaction do
        SendingPause.resume!(account)

        record!('sending.resume', account:, reason:,
                                  details: { was_paused_at: paused_at.iso8601 }.merge(details))
      end
    end
  end
end
