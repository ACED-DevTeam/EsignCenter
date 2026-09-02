# frozen_string_literal: true

module SendWebhookRequest
  USER_AGENT = 'EsignCenter Webhook'

  LOCALHOSTS = DownloadUtils::LOCALHOSTS

  MANUAL_ATTEMPT = 99_999
  AUTOMATED_RETRY_RANGE = 1..(MANUAL_ATTEMPT - 1)

  HttpsError = Class.new(StandardError)
  LocalhostError = Class.new(StandardError)
  MetadataHostError = Class.new(StandardError)

  SIGNATURE_HEADERS = %w[X-Docuseal-Signature X-Esigncenter-Signature].freeze

  # Cloud instance-metadata / link-local targets are never a legitimate
  # webhook receiver — posting there is an SSRF primitive (AWS/GCP/Azure
  # credentials live at 169.254.169.254). Blocked unconditionally, unlike the
  # localhost rule (self-hosted dev legitimately posts to localhost).
  METADATA_HOSTS = ['169.254.169.254', 'metadata.google.internal', 'metadata.goog'].freeze
  # String-prefix checks over the URL host: IPv4 link-local, IPv6 link-local
  # (fe80::/10 — URI hosts come bracketed), and IPv4-mapped IPv6 forms of the
  # same. Deliberately NOT a resolver-based check: in this product webhook
  # URLs are set only by the trusted provisioning path (admin token), so this
  # guards against configuration mistakes and the obvious literal forms, not
  # a hostile DNS-rebinding attacker.
  LINK_LOCAL_PREFIXES = ['169.254.', '[fe80:', 'fe80:', '[::ffff:169.254.', '::ffff:169.254.'].freeze

  module_function

  def call(webhook_url, event_uuid:, event_type:, record:, data:, attempt: 0)
    # Webhooks are paid-only. Every webhook job lands here, so a delivery
    # queued before a downgrade makes no request and records nothing (D43 —
    # the URL row stays, inert).
    return unless Entitlements.allowed?(webhook_url.account, :webhooks)

    uri = validate_webhook_uri!(webhook_url)

    webhook_event = create_webhook_event(webhook_url, event_uuid:, event_type:, record:)

    return if AUTOMATED_RETRY_RANGE.cover?(attempt.to_i) && webhook_event&.status == 'success'

    response = Faraday.post(uri) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['User-Agent'] = USER_AGENT
      req.headers.merge!(webhook_url.secret.to_h) if webhook_url.secret.present?

      req.body = {
        event_type: event_type,
        timestamp: webhook_event&.created_at || Time.current,
        data: data
      }.to_json

      add_signature_headers!(req.headers, webhook_url, body: req.body)

      req.options.read_timeout = 15
      req.options.open_timeout = 8
    end

    handle_response(webhook_event, response:, attempt:)
  rescue Faraday::SSLError, Faraday::TimeoutError, Faraday::ConnectionFailed => e
    handle_error(webhook_event, attempt:, error_message: e.class.name.split('::').last)
  rescue Faraday::Error => e
    handle_error(webhook_event, attempt:, error_message: e.message&.truncate(100))
  end

  def validate_webhook_uri!(webhook_url)
    uri = parse_uri(webhook_url.url)
    host = uri.host.to_s.downcase

    if host.in?(METADATA_HOSTS) || LINK_LOCAL_PREFIXES.any? { |prefix| host.start_with?(prefix) }
      raise MetadataHostError, "Can't send to a link-local/metadata address."
    end

    account = webhook_url.account

    # infra-keep: the HTTPS/localhost rules already apply to every customer account (Session 1).
    return uri unless Docuseal.multitenant? || account.customer?

    invalid_https = uri.scheme != 'https' || [443, nil].exclude?(uri.port)

    if invalid_https &&
       (account.customer? || !AccountConfig.exists?(account_id: account.id, key: :allow_http))
      raise HttpsError, 'Only HTTPS is allowed.'
    end

    raise LocalhostError, "Can't send to localhost." if host.in?(LOCALHOSTS)

    uri
  end

  def add_signature_headers!(headers, webhook_url, body:)
    signature = WebhookUrls::Signatures.sign(webhook_url.hmac_secret, body:)

    SIGNATURE_HEADERS.each do |header|
      headers[header] = signature if headers[header].blank?
    end
  end

  def parse_uri(url)
    URI(url)
  rescue URI::Error
    Addressable::URI.parse(url).normalize
  end

  def create_webhook_event(webhook_url, event_uuid:, event_type:, record:)
    return if event_uuid.blank?

    WebhookEvent.create_with(
      event_type:,
      record:,
      account_id: webhook_url.account_id,
      status: 'pending'
    ).find_or_create_by!(webhook_url:, uuid: event_uuid)
  end

  def handle_response(webhook_event, response:, attempt:)
    return response unless webhook_event

    is_error = response.status.to_i >= 400

    WebhookAttempt.create!(
      webhook_event:,
      response_body: is_error ? response.body&.truncate(100) : nil,
      response_status_code: response.status,
      attempt:
    )

    webhook_event.update!(status: is_error ? 'error' : 'success')

    response
  rescue StandardError
    raise if Rails.env.local?

    nil
  end

  def handle_error(webhook_event, error_message:, attempt:)
    return unless webhook_event

    WebhookAttempt.create!(
      webhook_event:,
      response_body: error_message,
      response_status_code: 0,
      attempt:
    )

    webhook_event.update!(status: 'error')

    nil
  rescue StandardError
    raise if Rails.env.local?

    nil
  end
end
