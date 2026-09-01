# frozen_string_literal: true

module EmbedOrigins
  LOCAL_HTTP_HOSTS = ['localhost', '127.0.0.1', '::1'].freeze
  INVALID_ORIGIN_MESSAGE = 'embed_origin must be an https origin like https://app.example.com, ' \
                           'or an http://localhost (or *.localhost subdomain) origin for local development'

  module_function

  def validate!(origin)
    uri = URI.parse(origin.to_s)

    return true if valid_origin_uri?(uri) && secure_or_local_origin?(uri)

    raise Params::BaseValidator::InvalidParameterError, INVALID_ORIGIN_MESSAGE
  rescue URI::InvalidURIError
    raise Params::BaseValidator::InvalidParameterError, INVALID_ORIGIN_MESSAGE
  end

  def normalize(origin)
    validate!(origin)

    uri = URI.parse(origin.to_s)
    port = uri.port if uri.port && uri.port != uri.default_port
    host = uri.hostname.to_s
    host = "[#{host}]" if host.include?(':') && !host.start_with?('[')

    [uri.scheme, '://', host, (":#{port}" if port)].compact.join
  end

  # Flatten one or more origin inputs (a string, a comma-joined string, or an
  # array of those) into a clean list of individual origin strings.
  def collect(*values)
    values.flatten.flat_map { |value| value.to_s.split(',') }.map(&:strip).compact_blank
  end

  # collect + validate + normalize, de-duplicated. Used to persist the full set
  # of origins allowed to embed a single signing session.
  def normalize_all(*values)
    collect(*values).map { |origin| normalize(origin) }.uniq
  end

  def valid_origin_uri?(uri)
    uri.is_a?(URI::HTTP) &&
      uri.hostname.present? &&
      uri.userinfo.blank? &&
      uri.path.in?(['', '/']) &&
      uri.query.blank? &&
      uri.fragment.blank?
  end

  def secure_or_local_origin?(uri)
    return true if uri.scheme == 'https'

    uri.scheme == 'http' && local_http_host?(uri.hostname)
  end

  # `.localhost` is a reserved TLD that always resolves to the loopback address
  # (RFC 6761), so any `*.localhost` subdomain is a local-development origin and
  # can never be a routable public host. Upstream apps that serve each tenant on
  # its own subdomain (e.g. http://acme.localhost:3060) rely on this in dev.
  def local_http_host?(hostname)
    host = hostname.to_s.downcase

    LOCAL_HTTP_HOSTS.include?(host) || host.end_with?('.localhost')
  end
end
