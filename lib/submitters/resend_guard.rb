# frozen_string_literal: true

module Submitters
  # The one gate every door passes before it emails a signing request to a
  # signer who ALREADY exists: a resend (one signer or the whole document),
  # an address correction with "send email" ticked, the API's
  # `PUT /api/submitters/:id` with `send_email`, and a signer delegating the
  # document to somebody else (launch security review, finding 2).
  #
  # The FIRST request of a document is bounded by the send quota — creating
  # the document is what spends it. Nothing above bounded the requests sent
  # after that: one document, one send, and then as many emails from our
  # sending address as a script could ask for, to any address it liked. So,
  # in this order:
  #
  #   1. a sending pause (lib/sending_pause.rb) refuses every one of them —
  #      paid or free, it is abuse policy, not quota;
  #   2. one signer gets at most Limits::RESENDS_PER_SIGNER_PER_DAY a UTC day,
  #      counted on the signer ROW, so changing the address in between is
  #      still the same signer;
  #   3. the billing account's resends are counted per UTC day: a FREE account
  #      is refused past Limits::FREE_RESENDS_PER_DAY; a PAID one is never
  #      refused (D42) but raises a `resend_velocity` review flag past
  #      Limits::PAID_RESENDS_PER_DAY_PER_SEAT per seat.
  #
  # Counts are durable (AccountCounters, one atomic upsert each), so a burst
  # of parallel requests cannot all read "not yet". A refused request still
  # counts: it only ever makes the refusal hold for the rest of the day.
  #
  # Internal and operator accounts are exempt from all three, exactly as
  # they are from every quota (and SendingPause never pauses them anyway).
  module ResendGuard
    ACCOUNT_KEY = 'signature_request_resends'
    SIGNER_KEY_PREFIX = 'signature_request_resends:signer:'

    module_function

    # Raises Quotas::LimitReached (:sending_paused, :signer_resends or
    # :resends) when the request must not be sent; true otherwise.
    def claim!(submitter)
      billing = Plans.billing_account(submitter.account)
      plan = Plans.key_for(billing)

      return true if plan == Plans::INTERNAL

      raise Quotas::LimitReached, :sending_paused if SendingPause.paused?(billing)

      claim_signer!(submitter)
      claim_account!(billing, plan)

      true
    end

    # The UTC day the counters above reset at the end of.
    def resets_at
      Time.current.utc.beginning_of_day.tomorrow
    end

    def resends_today(account)
      AccountCounters.value(Plans.billing_account(account).id, ACCOUNT_KEY, period: AccountCounters.day_period)
    end

    def claim_signer!(submitter)
      limit = Quotas::Limits::RESENDS_PER_SIGNER_PER_DAY
      count = AccountCounters.increment!(submitter.account_id, "#{SIGNER_KEY_PREFIX}#{submitter.id}",
                                         period: AccountCounters.day_period)

      return if count <= limit

      raise Quotas::LimitReached.new(:signer_resends, limit:, resets_at:)
    end

    def claim_account!(billing, plan)
      count = AccountCounters.increment!(billing.id, ACCOUNT_KEY, period: AccountCounters.day_period)

      if plan == Plans::FREE
        limit = Quotas::Limits::FREE_RESENDS_PER_DAY

        raise Quotas::LimitReached.new(:resends, limit:, resets_at:) if count > limit
      else
        flag_paid_velocity(billing, count)
      end
    end

    # Warn-flag only (D42): never raises, never blocks.
    def flag_paid_velocity(billing, count)
      seats = Quotas.limits_for(billing).seats || 1

      return if count <= Quotas::Limits::PAID_RESENDS_PER_DAY_PER_SEAT * seats

      AbuseFlags.record!(billing, 'resend_velocity', period: AccountCounters.day_period,
                                                     details: { resends_today: count, seats: })
    rescue StandardError => e
      ErrorReport.error(e, account_id: billing.id)
    end
  end
end
