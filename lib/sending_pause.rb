# frozen_string_literal: true

# The one automatic sending stop that applies to every customer account, paid
# included: a spam complaint, or hard bounces among the last few sends, pause
# the creation of new documents until the operator resumes the account.
# Abuse policy, not quota — nothing here depends on the plan. Enforced inside
# Quotas.assert_can_create_submissions! on every creation path; documents
# already sent keep completing, downloads keep working.
#
# Session 8's Postmark webhook calls `evaluate!` after it records an
# EmailEvent; nothing calls it yet.
module SendingPause
  COMPLAINT_EVENTS = %w[complaint spam_complaint].freeze
  HARD_BOUNCE_EVENTS = %w[bounce permanent_bounce hard_bounce].freeze
  REASONS = %w[complaint bounce_rate].freeze
  FLAG_KINDS = %w[complaint bounce_rate].freeze

  module_function

  def paused?(account)
    billing = Plans.billing_account(account)

    return false if billing.internal? || billing.operator?

    billing.sending_paused_at.present?
  end

  # Idempotent: an account already paused keeps its first reason and gets no
  # second email. The check and the write happen under the account's row lock
  # (two webhook deliveries at once cannot both "win"), and the flag, the
  # mail and the operator alert go out only from the call that changed the
  # state.
  def pause!(account, reason:, details: {})
    billing = Plans.billing_account(account)

    return billing if billing.internal? || billing.operator?

    paused_now = billing.with_lock do
      next false if billing.sending_paused_at.present?

      billing.update!(sending_paused_at: Time.current, sending_pause_reason: reason)

      true
    end

    return billing unless paused_now

    AbuseFlags.record!(billing, reason == 'complaint' ? 'complaint' : 'bounce_rate',
                       period: AccountCounters.month_period, details:)

    QuotaMailer.sending_paused(billing, reason).deliver_later!

    OperatorAlert.deliver(
      subject: "Sending paused for account #{billing.id} (#{reason})",
      body: "Sending was paused automatically on account #{billing.id} (#{billing.name}).\n" \
            "Reason: #{reason}\nDetails: #{details.to_json}\n\n" \
            "Review the account, then lift the pause with: rake \"operator:resume_sending[#{billing.id}]\""
    )

    billing
  end

  def resume!(account)
    billing = Plans.billing_account(account)

    billing.update!(sending_paused_at: nil, sending_pause_reason: nil)
    billing.abuse_flags.open.where(kind: FLAG_KINDS).update_all(resolved_at: Time.current)

    billing
  end

  # Called with an EmailEvent after it is recorded.
  def evaluate!(account, event:)
    billing = Plans.billing_account(account)

    if COMPLAINT_EVENTS.include?(event.event_type)
      pause!(billing, reason: 'complaint', details: { email_event_id: event.id, email: event.email })
    elsif HARD_BOUNCE_EVENTS.include?(event.event_type) && (rate = bounce_rate(billing))
      pause!(billing, reason: 'bounce_rate', details: { email_event_id: event.id, bounce_rate: rate })
    end

    nil
  end

  # The share of the last BOUNCE_WINDOW deliveries that hard-bounced, when it
  # is at or above BOUNCE_PAUSE_RATE and at least BOUNCE_MIN_SENDS went out;
  # nil otherwise. A delivery is one (message, recipient) pair: a message to
  # several recipients records one send event per recipient under the same
  # message_id (lib/action_mailer_events_observer.rb), and each recipient
  # bounces on its own.
  def bounce_rate(billing)
    ids = Quotas.account_ids(billing)

    deliveries = EmailEvent.where(account_id: ids, event_type: 'send')
                           .order(event_datetime: :desc)
                           .limit(Quotas::Limits::BOUNCE_WINDOW)
                           .pluck(:message_id, :email)
                           .map { |message_id, email| [message_id, email.to_s.downcase] }
                           .uniq

    return nil if deliveries.size < Quotas::Limits::BOUNCE_MIN_SENDS

    bounced = EmailEvent.where(account_id: ids, event_type: HARD_BOUNCE_EVENTS,
                               message_id: deliveries.map(&:first))
                        .pluck(:message_id, :email)
                        .map { |message_id, email| [message_id, email.to_s.downcase] }

    rate = (deliveries & bounced).size.to_f / deliveries.size

    rate >= Quotas::Limits::BOUNCE_PAUSE_RATE ? rate : nil
  end
end
