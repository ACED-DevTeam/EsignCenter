# frozen_string_literal: true

# The Stripe end of the billing loop. Its whole contract is: verify the
# signature, store the exact bytes Stripe signed, acknowledge. Nothing is
# decided here and nothing is processed inline — a slow or broken processor
# must never make Stripe give up on a delivery, and a repeated delivery of an
# event we already hold must cost nothing.
#
# Deliberately NOT behind the BILLING_ENABLED launch gate: the switch controls
# whether customers can reach the billing pages, not whether Stripe may talk
# to us. A subscription created before the switch was flipped off still
# changes state, and losing those events would leave the app's idea of who is
# paying permanently wrong.
class StripeWebhooksController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :verify_authenticity_token
  skip_before_action :maybe_redirect_to_setup
  skip_authorization_check

  def create
    if StripeBilling.webhook_secret.blank?
      Rails.logger.error('Stripe webhook rejected: STRIPE_WEBHOOK_SECRET is not set')

      return head :service_unavailable
    end

    raw_body = request.raw_post
    event = verified_event(raw_body)

    return head :bad_request if event.nil?

    store_and_enqueue(raw_body, event)

    render json: { received: true }
  end

  private

  # A body we cannot prove came from Stripe is refused with a bare 400: the
  # response never says which part of the header was wrong.
  def verified_event(raw_body)
    StripeBilling.webhook_event!(raw_body, request.headers['Stripe-Signature'])
  rescue Stripe::SignatureVerificationError, JSON::ParserError, ArgumentError => e
    Rails.logger.warn("Stripe webhook signature rejected (#{e.class})")

    nil
  end

  # The event id is the deduplication key: Stripe retries a delivery until it
  # is acknowledged, so the same event arrives more than once as a matter of
  # course. A second copy never makes a second ROW — but it does put the
  # stored one back on the queue when it has not been decided yet.
  def store_and_enqueue(raw_body, event)
    inbox = StripeEventInbox.new(
      stripe_event_id: event['id'],
      event_type: event['type'],
      api_version: event['api_version'],
      payload: raw_body,
      status: StripeEventInbox::PENDING,
      stripe_created_at: event['created'] && Time.zone.at(event['created'])
    )

    if inbox.save
      ProcessStripeEventJob.perform_async(inbox.id)
    else
      requeue_stored(event)
    end
  rescue ActiveRecord::RecordNotUnique
    requeue_stored(event)
  end

  # The row committed but its job did not: `perform_async` raised (Redis was
  # down) and Stripe got a 500, or the worker that had it died. Stripe's own
  # retry is the earliest chance to put it back on the queue — otherwise it
  # waits for the 06:00 sweep.
  def requeue_stored(event)
    stored = StripeEventInbox.find_by(stripe_event_id: event['id'])

    unless requeuable?(stored)
      Rails.logger.info("Stripe webhook #{event['id']} needs no second job; not re-enqueued")

      return
    end

    Rails.logger.info("Stripe webhook #{event['id']} already stored; re-enqueued")

    ProcessStripeEventJob.perform_async(stored.id)
  end

  # Only a row that is genuinely waiting for a worker. A `processing` row
  # belongs to a worker right now — the stuck-row sweep is what decides that
  # worker died, and a second job would bump `attempts` a second time and
  # could push a retryable row out of the retry budget. A `failed` row that
  # has spent MAX_ATTEMPTS was deliberately given up on; re-enqueueing it
  # from a dashboard "Resend" would make this door disagree with
  # `StripeEventInbox.retryable` and with the reconciliation sweep. Anything
  # already processed or ignored has its verdict.
  def requeuable?(stored)
    case stored&.status
    when StripeEventInbox::PENDING then true
    when StripeEventInbox::FAILED then stored.attempts < StripeEventInbox::MAX_ATTEMPTS
    else false
    end
  end
end
