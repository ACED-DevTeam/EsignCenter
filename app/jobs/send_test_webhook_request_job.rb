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

    uri = SendWebhookRequest.validate_webhook_uri!(webhook_url)
    body = {
      event_type: 'form.completed',
      timestamp: Time.current.iso8601,
      data: Submitters::SerializeForWebhook.call(submitter)
    }.to_json

    Faraday.post(uri) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['User-Agent'] = USER_AGENT
      req.headers.merge!(webhook_url.secret.to_h) if webhook_url.secret.present?
      req.body = body

      SendWebhookRequest.add_signature_headers!(req.headers, webhook_url, body:)
    end
  end
end
