# frozen_string_literal: true

class SendTestWebhookRequestJob
  include Sidekiq::Job

  sidekiq_options retry: 0

  USER_AGENT = 'EsignCenter Webhook'

  def perform(params = {})
    submitter = Submitter.find_by(id: params['submitter_id'])

    return unless submitter

    webhook_url = WebhookUrl.find_by(id: params['webhook_url_id'])

    return unless webhook_url

    # Webhooks are paid-only. A test send queued for (or by) an account that
    # is no longer entitled makes no request (D43 — the URL row stays, inert),
    # the same as every real delivery in SendWebhookRequest.
    return unless Entitlements.allowed?(webhook_url.account, :webhooks)

    uri = SendWebhookRequest.validate_webhook_uri!(webhook_url)
    address = SendWebhookRequest.deliverable_address!(uri, webhook_url.account)
    body = {
      event_type: 'form.completed',
      timestamp: Time.current.iso8601,
      data: Submitters::SerializeForWebhook.call(submitter)
    }.to_json

    SendWebhookRequest.post(uri, address) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['User-Agent'] = USER_AGENT
      req.headers.merge!(webhook_url.secret.to_h) if webhook_url.secret.present?
      req.body = body

      SendWebhookRequest.add_signature_headers!(req.headers, webhook_url, body:)
    end
  end
end
