# frozen_string_literal: true

# The public support form: GET /support renders it, POST /support sends one
# email and shows a receipt (Session 10 Phase B, docs/marketing-pages.md).
#
# Public in exactly the way MarketingController and LegalController are — the
# people who most need to reach us are a signer with no account and somebody
# who cannot get INTO theirs. Signed-in visitors get their name and address
# filled in and fixed, because a support message from an account should be
# answerable at the address we already know.
#
# Nothing is written to the database: there is no support table, no ticket id
# and nothing to leak later. The message is an email to a mailbox a person
# reads (SupportMailer).
#
# Three guards, in this order, and the order is the point:
#
#   1. the per-IP hourly limit, spent first, because everything after it costs
#      the server real work an anonymous stranger must not be able to order in
#      bulk — the Cloudflare round-trip above all (the same reasoning as
#      RegistrationsController's attempt ceiling);
#   2. the honeypot, which answers with the ORDINARY receipt and sends
#      nothing, so a script is never told it was caught;
#   3. Turnstile, then the form's own validation.
#
# Turnstile is enforced when the instance HAS Turnstile keys, and skipped when
# it does not — the one place this form deliberately differs from sign-up,
# which fails closed. Sign-up creates an account and is switched off entirely
# without the keys (RegistrationConfigGuard); support is how somebody locked
# out of their account reaches a human, and a form that refuses everybody
# because a third-party key is missing is a form that has failed. On such an
# instance the honeypot and the per-IP limit are the brakes, exactly as they
# are on the abuse-report form (ReportsController), and no widget and no
# third-party script are rendered at all.
class SupportRequestsController < ApplicationController
  include TurnstileProtected

  layout 'marketing'

  REQUESTS_PER_IP_PER_HOUR = 5

  # A field no human sees and no browser fills. A bot that fills every input
  # on the page names itself by writing here.
  HONEYPOT_FIELD = 'website'

  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_english

  # The form is the only page in the application other than sign-up that
  # carries the widget, so it is the only other page whose policy is widened
  # (TurnstileProtected: GET only, after set_csp).
  protect_with_turnstile only: %i[new]

  def new
    @support_request = SupportRequest.new(prefill)
  end

  def create
    return render :too_many_requests, status: :too_many_requests unless ip_allowed?

    @support_request = SupportRequest.new(support_request_params.merge(prefill))

    # Caught by the honeypot: the receipt a person gets, rendered from the same
    # object and so byte for byte the same page, and no mail. A script is never
    # told it was caught.
    return render :create unless params[HONEYPOT_FIELD].to_s.strip.empty?

    return refuse(:please_complete_the_verification) if Turnstile.configured? && !turnstile_passed?
    return render :new, status: :unprocessable_content unless @support_request.valid?

    deliver!

    render :create
  end

  private

  # Signed in, the name and the address are ours, not the form's: the fields
  # are shown read-only and whatever was posted for them is discarded.
  def prefill
    return {} unless signed_in?

    { name: current_user.full_name, email: current_user.email }
  end

  def support_request_params
    return {} unless params[:support_request].respond_to?(:permit)

    params.require(:support_request).permit(:name, :email, :topic, :message)
  end

  def refuse(message_key)
    @support_request.errors.add(:base, I18n.t(message_key))

    render :new, status: :unprocessable_content
  end

  def ip_allowed?
    RateLimit.call("support-ip-hour-#{request.remote_ip}", limit: REQUESTS_PER_IP_PER_HOUR, ttl: 1.hour)

    true
  rescue RateLimit::LimitApproached
    false
  end

  def deliver!
    SupportMailer.request_received(
      name: @support_request.name,
      email: @support_request.email,
      topic: @support_request.topic,
      topic_label: @support_request.topic_label,
      message: @support_request.message,
      ip: request.remote_ip,
      account_facts:
    ).deliver_later!
  end

  # Server-derived, every one of them. A signed-out visitor has none.
  def account_facts
    return nil unless signed_in?

    { id: current_account.id, name: current_account.name, kind: current_account.account_kind,
      plan: Plans.key_for(current_account), user_id: current_user.id, user_email: current_user.email }
  end
end
