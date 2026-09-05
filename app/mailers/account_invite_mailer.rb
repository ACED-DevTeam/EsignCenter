# frozen_string_literal: true

# The invitation itself: one email to one person, with a link that is good for
# BillingLifecycle::INVITE_TOKEN_DAYS days.
#
# Two versions of the same mail, because there are two situations:
#   * a fresh address — "join <Team>, here is where you set your password";
#   * an address that already has an EsignCenter account of its own — the same
#     invitation, plus the plain truth about what accepting does: everything
#     in their own account moves into the team (D50). Nobody should learn that
#     from a confirmation dialog after clicking.
#
# The raw token is passed in rather than read off the record, because the
# record only ever holds its digest: the one object that knows the token is
# the one that just minted it (AccountInvites.reserve!).
#
# English-only copy like BillingMailer and QuotaMailer: this is platform mail
# about an account, not a document a signer has to read in their own language.
# `mail_account` so the interceptor picks the right outgoing server; no
# message metadata, because an invitation is not an emailable record.
class AccountInviteMailer < ApplicationMailer
  def invitation(invite, raw_token)
    raise ArgumentError, 'the invitation has no token to send' if raw_token.blank?

    @invite = invite
    @account = invite.account
    @inviter_name = invite.invited_by&.full_name.presence || invite.account.name
    @collision_user = invite.collision_user
    @accept_url = invite_url(token: raw_token)
    @expires_in_days = BillingLifecycle::INVITE_TOKEN_DAYS
    mail_account(@account)

    mail(to: invite.email, subject: "#{@inviter_name} invited you to join #{@account.name} on EsignCenter")
  end

  private

  # Written by the platform, not by a customer: the mail layout signs it
  # with the product's name and the support address whatever the account's
  # branding-removal setting says (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
