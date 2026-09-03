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
  # course. A second copy is acknowledged without a second job.
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
      Rails.logger.info("Stripe webhook #{event['id']} already stored; not re-enqueued")
    end
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("Stripe webhook #{event['id']} raced a duplicate delivery; not re-enqueued")
  end
end
