# frozen_string_literal: true

# The one automatic sending stop that applies to every customer account, paid
# included: a spam complaint, or hard bounces among the last few sends, pause
# the creation of new documents until the operator resumes the account.
# Abuse policy, not quota — nothing here depends on the plan. Enforced inside
# Quotas.assert_can_create_submissions! on every creation path; documents
# already sent keep completing, downloads keep working.
#
# The Postmark webhook calls `evaluate!` after it records an EmailEvent.
module SendingPause
  COMPLAINT_EVENTS = %w[complaint spam_complaint].freeze
  HARD_BOUNCE_EVENTS = %w[bounce permanent_bounce hard_bounce].freeze
  REASONS = %w[complaint bounce_rate].freeze
  FLAG_KINDS = %w[complaint bounce_rate].freeze

  # Every event type that can feed the automatic pause, derived from the two
  # lists above rather than restated. A caller that keeps its own copy of this
  # is a caller that stops feeding the pause the day a spelling is added here
  # and nobody remembers the second list (review 1, A-L2).
  PAUSE_EVENTS = (COMPLAINT_EVENTS + HARD_BOUNCE_EVENTS).freeze

  # The mail this policy is about: what an account sends its signers. Every
  # other send row belongs to the platform's own mail to the account's
  # administrators (Session 10, review 8 C3) and is deliberately outside it.
  SIGNER_EMAILABLE_TYPE = 'Submitter'

  module_function

  # Reads the column fresh rather than the object's copy: the account a
  # creation path holds was loaded before it took the creation lock, so a
  # pause committed in between would be invisible on that object.
  def paused?(account)
    state(account).first.present?
  end

  # [sending_paused_at, sending_pause_reason] of the billing account, read in
  # one statement so a banner never shows a pause without its reason (or the
  # reverse). Internal and operator accounts are never paused.
  def state(account)
    billing = Plans.billing_account(account)

    return [nil, nil] unless billing.customer?

    Account.where(id: billing.id).pick(:sending_paused_at, :sending_pause_reason)
  end

  # Idempotent: an account already paused keeps its first reason and gets no
  # second email. The check and the write happen under the account's row lock
  # (two webhook deliveries at once cannot both "win"), and the flag, the
  # mail and the operator alert go out only from the call that changed the
  # state.
  def pause!(account, reason:, details: {})
    billing = Plans.billing_account(account)

    return billing unless billing.customer?

    # Creation advisory lock first, account row second, just like creators.
    # The flag is written under the same lock as the pause, so a resume that
    # lands right after sees (and resolves) it instead of racing past it.
    paused_now = Quotas.with_creation_lock(billing) do
      billing.with_lock do
        next false if billing.sending_paused_at.present?

        billing.update!(sending_paused_at: Time.current, sending_pause_reason: reason)

        AbuseFlags.record!(billing, reason == 'complaint' ? 'complaint' : 'bounce_rate',
                           period: AccountCounters.month_period, details:)

        true
      end
    end

    return billing unless paused_now

    notify_operator(billing, reason, details)
    notify_customer(billing, reason)

    billing
  end

  # State failures propagate to the webhook transaction. Notifications are
  # independent best-effort handoffs: an operator alert goes first, and a
  # failure of either message never suppresses the other or undoes the pause.
  def notify_operator(billing, reason, details)
    OperatorAlert.deliver(
      subject: "Sending paused for account #{billing.id} (#{reason})",
      body: "Sending was paused automatically on account #{billing.id} (#{billing.name}).\n" \
            "Reason: #{reason}\nDetails: #{details.to_json}\n\n" \
            "Review the account, then lift the pause with: rake \"operator:resume_sending[#{billing.id}]\""
    )
  rescue StandardError => e
    ErrorReport.error(e, account_id: billing.id)
  end

  def notify_customer(billing, reason)
    QuotaMailer.sending_paused(billing, reason).deliver_later!
  rescue StandardError => e
    ErrorReport.error(e, account_id: billing.id)
  end

  # Under the same row lock as pause!: the two writes land together, and a
  # pause arriving at the same moment is either fully before or fully after.
  #
  # THE WATERMARK IS THE POINT (review 8, A1). Clearing the pause used to be
  # all this did, and the bounce window it is judged by is the last
  # BOUNCE_WINDOW deliveries — which, a second after a resume, are the very
  # deliveries that caused the pause. So the next bounce re-paused the account
  # instantly, and the console's Resume button could not lift a `bounce_rate`
  # pause at all: it lifted it and the account was back inside the minute.
  # `sending_resumed_at` is where the window starts from now on. Deliveries
  # before a resume are history — an operator has looked at them and decided —
  # and the next pause has to be earned by mail sent AFTER that decision.
  def resume!(account)
    billing = Plans.billing_account(account)

    Quotas.with_creation_lock(billing) do
      billing.with_lock do
        billing.update!(sending_paused_at: nil, sending_pause_reason: nil, sending_resumed_at: Time.current)
        billing.abuse_flags.open.where(kind: FLAG_KINDS).update_all(resolved_at: Time.current)
      end
    end

    billing
  end

  # Is this event type one the pause cares about at all? Asked by the Postmark
  # webhook before it opens the pause path, so the webhook does not have to
  # know which spellings count.
  def pause_trigger?(event_type)
    PAUSE_EVENTS.include?(event_type.to_s)
  end

  # Called with an EmailEvent after it is recorded.
  #
  # SIGNER MAIL ONLY, and that is a policy statement, not an optimisation
  # (Session 10, C3). Since the SaaS lifecycle mail is tracked too, this is
  # now asked about dunning letters, invitations and quota warnings as well —
  # and an account must never be stopped from sending because OUR letter to
  # THEM bounced. The pause is about the mail an account sends its signers:
  # that is what a complaint is a complaint about, and that is the only mail
  # counted in `bounce_rate` below.
  def evaluate!(account, event:)
    return nil unless counts_towards_pause?(event)

    billing = Plans.billing_account(account)

    if COMPLAINT_EVENTS.include?(event.event_type)
      pause!(billing, reason: 'complaint', details: { email_event_id: event.id, email: event.email })
    elsif HARD_BOUNCE_EVENTS.include?(event.event_type) && (rate = bounce_rate(billing))
      pause!(billing, reason: 'bounce_rate', details: { email_event_id: event.id, bounce_rate: rate })
    end

    nil
  end

  # Mail an account sent its SIGNERS. Every send row the abuse pause looks at
  # is one of these; a row attributed to the account itself is platform mail
  # from us to them (lib/action_mailer_events_observer.rb, review 8 C3).
  def counts_towards_pause?(event)
    event.emailable_type == SIGNER_EMAILABLE_TYPE
  end

  # The share of the last BOUNCE_WINDOW deliveries that hard-bounced, when it
  # is at or above BOUNCE_PAUSE_RATE and at least BOUNCE_MIN_SENDS went out;
  # nil otherwise. A delivery is one (message, recipient) pair: a message to
  # several recipients records one send event per recipient under the same
  # message_id (lib/action_mailer_events_observer.rb), and each recipient
  # bounces on its own. The window is BOUNCE_WINDOW distinct deliveries: the
  # pairs are made distinct BEFORE the window is cut, so a message that
  # carries the same address twice (to and cc) never shrinks it.
  def bounce_rate(billing)
    ids = Quotas.account_ids(billing)

    return nil if (deliveries = recent_deliveries(ids)).size < Quotas::Limits::BOUNCE_MIN_SENDS

    # No watermark on this side: the window above is already only deliveries
    # made since the resume, and a bounce is dated by the PROVIDER's clock —
    # Postmark reports "bounced at" from its own timestamp, which can read
    # earlier than our resume even for a message we sent afterwards. What
    # matters is which delivery it belongs to.
    bounced = signer_events(ids, HARD_BOUNCE_EVENTS).where(message_id: deliveries.map(&:first))
                                                    .pluck(:message_id, :email)
                                                    .map { |message_id, email| [message_id, email.to_s.downcase] }

    rate = (deliveries & bounced).size.to_f / deliveries.size

    rate >= Quotas::Limits::BOUNCE_PAUSE_RATE ? rate : nil
  end

  # Signer mail of this family, of these types: the one filter both sides of
  # the bounce maths share, so a window and the bounces measured against it can
  # never be drawn from different sets of mail (review 8, C3).
  def signer_events(ids, event_types)
    EmailEvent.where(account_id: ids, event_type: event_types, emailable_type: SIGNER_EMAILABLE_TYPE)
  end

  # When the operator last let this family send again, or nil. The bounce
  # window starts here (review 8, A1).
  def resumed_at(ids)
    Account.where(id: ids).maximum(:sending_resumed_at)
  end

  # The newest BOUNCE_WINDOW distinct (message_id, email) pairs among the
  # send events, each pair dated by its latest event.
  def recent_deliveries(ids)
    sends = signer_events(ids, 'send')
    watermark = resumed_at(ids)
    sends = sends.where(event_datetime: watermark..) if watermark

    distinct_pairs =
      sends.select('DISTINCT ON (message_id, LOWER(email)) message_id, LOWER(email) AS email, event_datetime')
           .order(Arel.sql('message_id, LOWER(email), event_datetime DESC'))

    EmailEvent.from(distinct_pairs, :email_events)
              .order(event_datetime: :desc)
              .limit(Quotas::Limits::BOUNCE_WINDOW)
              .pluck(:message_id, :email)
              .map { |message_id, email| [message_id, email.to_s] }
  end
end
