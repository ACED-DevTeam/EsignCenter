# frozen_string_literal: true

module SendWebhookRequest
  USER_AGENT = 'EsignCenter Webhook'

  LOCALHOSTS = DownloadUtils::LOCALHOSTS

  MANUAL_ATTEMPT = 99_999
  AUTOMATED_RETRY_RANGE = 1..(MANUAL_ATTEMPT - 1)

  HttpsError = Class.new(StandardError)
  InvalidUrlError = Class.new(StandardError)
  LocalhostError = Class.new(StandardError)
  MetadataHostError = Class.new(StandardError)
  # A subclass, so every existing LocalhostError rescue (delivery, the model's
  # save-time message) also covers private and resolved-private targets.
  PrivateAddressError = Class.new(LocalhostError)

  NON_RETRYABLE_RESPONSE = Struct.new(:status, :final)
                                 .new(0, true)
                                 .freeze

  SIGNATURE_HEADERS = %w[X-Docuseal-Signature X-Esigncenter-Signature].freeze

  # Cloud instance-metadata / link-local targets are never a legitimate
  # webhook receiver — posting there is an SSRF primitive (AWS/GCP/Azure
  # credentials live at 169.254.169.254). Blocked unconditionally, unlike the
  # localhost rule (local development legitimately posts to localhost).
  METADATA_HOSTS = ['169.254.169.254', 'metadata.google.internal', 'metadata.goog'].freeze
  # String-prefix checks over the URL host: IPv4 link-local, IPv6 link-local
  # (fe80::/10 — URI hosts come bracketed), and IPv4-mapped IPv6 forms of the
  # same.
  LINK_LOCAL_PREFIXES = ['169.254.', '[fe80:', 'fe80:', '[::ffff:169.254.', '::ffff:169.254.'].freeze

  # Private/reserved address rules and pinning are shared with URL downloads
  # (OutboundAddress).
  BLOCKED_NETWORKS = OutboundAddress::BLOCKED_NETWORKS

  module_function

  def call(webhook_url, event_uuid:, event_type:, record:, data:, attempt: 0)
    # Webhooks are paid-only. Every webhook job lands here, so a delivery
    # queued before a downgrade makes no request and records nothing (D43 —
    # the URL row stays, inert). The terminal response stops the job's retry.
    return NON_RETRYABLE_RESPONSE unless Entitlements.allowed?(webhook_url.account, :webhooks)

    webhook_event = create_webhook_event(webhook_url, event_uuid:, event_type:, record:)

    return if AUTOMATED_RETRY_RANGE.cover?(attempt.to_i) && webhook_event&.status == 'success'

    uri = validate_webhook_uri!(webhook_url)
    address = deliverable_address!(uri, webhook_url.account)

    response = post(uri, address) do |req|
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
  rescue HttpsError, InvalidUrlError, LocalhostError, MetadataHostError => e
    handle_error(webhook_event, attempt:, error_message: e.message)

    NON_RETRYABLE_RESPONSE
  rescue Faraday::SSLError, Faraday::TimeoutError, Faraday::ConnectionFailed => e
    handle_error(webhook_event, attempt:, error_message: e.class.name.split('::').last)
  rescue Faraday::Error => e
    handle_error(webhook_event, attempt:, error_message: e.message&.truncate(100))
  end

  def validate_webhook_uri!(webhook_url)
    validate_url!(webhook_url.url, webhook_url.account)
  end

  # `strict:` defaults to this environment's rule; the release audit passes
  # `true` to ask what production would say (lib/release_internal_audit.rb).
  def validate_url!(url, account, strict: strict_rules?(account))
    uri = parse_uri(url)
    host = uri.host.to_s.downcase

    # A URL nothing can be posted to ("https:/path" parses as HTTPS with no
    # host; "not a url" has neither) is refused for every account before the
    # scheme rules, so a non-deliverable row is never saved or attempted.
    if host.blank? || %w[http https].exclude?(uri.scheme.to_s.downcase)
      raise InvalidUrlError, 'Not a valid http(s) URL.'
    end

    if host.in?(METADATA_HOSTS) || LINK_LOCAL_PREFIXES.any? { |prefix| host.start_with?(prefix) }
      raise MetadataHostError, "Can't send to a link-local/metadata address."
    end

    # Local development only: an internal/operator account outside production
    # may post to http://localhost (a paired app running on the same machine).
    # Production and every customer account get the full rules (D57).
    return uri unless strict

    invalid_https = uri.scheme != 'https' || [443, nil].exclude?(uri.port)

    # allow_http is a legacy non-production opt-out; in production (and for
    # customers anywhere) it never relaxes the HTTPS rule.
    if invalid_https &&
       (account.customer? || Rails.env.production? ||
        !AccountConfig.exists?(account_id: account.id, key: :allow_http))
      raise HttpsError, 'Only HTTPS is allowed.'
    end

    raise LocalhostError, "Can't send to localhost." if host.in?(LOCALHOSTS)

    literal = literal_ip(host)

    raise PrivateAddressError, "Can't send to a private address." if literal && blocked_ip?(literal)

    uri
  end

  def strict_rules?(account)
    Docuseal.multitenant? || account.customer? || Rails.env.production?
  end

  # The address the request must connect to, or nil for "let the HTTP client
  # resolve it". Under the strict rules the host is resolved HERE, every
  # answer is checked, and the request is pinned to the checked address — so a
  # name that resolves to an internal address is refused, and a DNS answer
  # that changes between the check and the connect (rebinding) cannot redirect
  # the request.
  #
  # The local-development allowance (see validate_url!) still refuses a name
  # that aliases a metadata/link-local address, but never pins and never fails
  # on a lookup it cannot make: Net::HTTP picks between localhost's IPv4 and
  # IPv6 answers itself, and mDNS/compose names keep working.
  def deliverable_address!(uri, account, strict: strict_rules?(account))
    host = uri.host.to_s.downcase
    addresses = literal_ip(host) ? [literal_ip(host)] : resolve_addresses(host)

    raise MetadataHostError, "Can't send to a link-local/metadata address." if addresses.any? { |ip| metadata_ip?(ip) }

    return unless strict

    raise Faraday::ConnectionFailed, 'Could not resolve host' if addresses.empty?
    raise PrivateAddressError, "Can't send to a private address." if addresses.any? { |ip| blocked_ip?(ip) }

    addresses.first.to_s
  end

  def resolve_addresses(host)
    OutboundAddress.resolve(host)
  end

  def literal_ip(host)
    OutboundAddress.literal_ip(host)
  end

  def blocked_ip?(ip)
    OutboundAddress.blocked_ip?(ip)
  end

  def metadata_ip?(ip)
    OutboundAddress.metadata_ip?(ip)
  end

  # Posts to `uri`, connecting to the checked `address` when there is one
  # (TLS keeps the hostname; see OutboundAddress.pinned_connection). Redirects
  # are never followed (no follow_redirects middleware): a 3xx is recorded as
  # the receiver's answer, so a public URL cannot bounce the signed payload to
  # an internal one.
  def post(uri, address, &)
    OutboundAddress.pinned_connection(address).post(uri) do |req|
      OutboundAddress.unproxied!(req, address)

      yield req
    end
  end

  def add_signature_headers!(headers, webhook_url, body:)
    signature = WebhookUrls::Signatures.sign(webhook_url.hmac_secret, body:)

    SIGNATURE_HEADERS.each do |header|
      headers[header] = signature if headers[header].blank?
    end
  end

  def parse_uri(url)
    URI(url.to_s)
  rescue URI::Error
    begin
      Addressable::URI.parse(url.to_s).normalize
    rescue Addressable::URI::InvalidURIError
      raise InvalidUrlError, 'Not a valid http(s) URL.'
    end
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
