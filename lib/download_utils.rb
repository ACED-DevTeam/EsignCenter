# frozen_string_literal: true

module DownloadUtils
  LOCALHOSTS = Set[
    '0.0.0.0',
    '127.0.0.1',
    '127.0.1.1',
    'localhost',
    'localhost.localdomain',
    '::1',
    '[::1]',
    'ip6-localhost',
    'ip6-loopback',
    '127.0.0.0',
    '127.255.255.255',
    '::',
    '0:0:0:0:0:0:0:1',
    '[0:0:0:0:0:0:0:1]',
    '0000:0000:0000:0000:0000:0000:0000:0001',
    '[0000:0000:0000:0000:0000:0000:0000:0001]',
    '::0',
    '0::0',
    '::ffff:127.0.0.1',
    '[::ffff:127.0.0.1]',
    '::ffff:7f00:1',
    '[::ffff:7f00:1]',
    'local',
    'localhost.local',
    'ip6-localnet',
    'ip6-allnodes',
    'ip6-allrouters'
  ].freeze

  UnableToDownload = Class.new(StandardError)
  # The response body passed `max_bytes` (the download stops there).
  TooLarge = Class.new(UnableToDownload)

  # Same budget as the follow_redirects middleware the unvalidated path uses.
  MAX_REDIRECTS = 3
  REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

  module_function

  # infra-keep: every caller that fetches a user-supplied URL passes validate: true explicitly;
  # the default only decides the behaviour for internal callers.
  #
  # A validated download is checked hop by hop: every URL (the first and each
  # redirect target) must be HTTPS on 443, not localhost, and must resolve only
  # to public addresses; the request is then pinned to the checked address
  # (OutboundAddress), so neither a DNS answer nor a redirect can steer it at
  # an internal service.
  #
  # With `max_bytes` the body is streamed and the download is abandoned as
  # soon as it exceeds the bound, so a large file never sits in memory whole;
  # the returned response carries the collected body as usual.
  def call(url, validate: Docuseal.multitenant?, max_bytes: nil)
    uri = parse_uri(url)

    resp = validate ? validated_get(uri, max_bytes:) : get(conn(validate:), uri, max_bytes:)

    raise UnableToDownload, "Error loading: #{uri}" if resp.status >= 400

    resp
  end

  def validated_get(uri, max_bytes:)
    (MAX_REDIRECTS + 1).times do
      validate_uri!(uri)

      address = public_address!(uri)
      resp = get(OutboundAddress.pinned_connection(address), uri, max_bytes:, address:)

      location = resp.headers['location']

      return resp unless REDIRECT_STATUSES.include?(resp.status) && location.present?

      uri = redirect_uri(uri, location)
    end

    raise UnableToDownload, "Error loading: #{uri}. Too many redirects."
  end

  def get(connection, uri, max_bytes: nil, address: nil)
    return bounded_get(connection, uri, max_bytes:, address:) if max_bytes

    connection.get(uri) { |req| OutboundAddress.unproxied!(req, address) }
  end

  def bounded_get(connection, uri, max_bytes:, address: nil)
    body = +''

    resp = connection.get(uri) do |req|
      OutboundAddress.unproxied!(req, address)

      req.options.on_data = proc do |chunk, received_bytes, env|
        # A redirect's own body streams through here too before the next hop;
        # only the final answer counts.
        next if env.status.to_i.between?(300, 399)

        raise TooLarge, "Error loading: #{uri}. The file is larger than #{max_bytes / 1.megabyte} MB." if
          received_bytes > max_bytes

        body << chunk
      end
    end

    resp.env.body = body

    resp
  end

  def validate_uri!(uri)
    raise UnableToDownload, "Error loading: #{uri}. Only HTTPS is allowed." if uri.scheme != 'https' ||
                                                                               [443, nil].exclude?(uri.port)
    raise UnableToDownload, "Error loading: #{uri}. Can't download from localhost." if uri.host.in?(LOCALHOSTS)
  end

  # Every address the host names must be public; the first is the one dialled.
  def public_address!(uri)
    addresses = OutboundAddress.addresses(uri.host)

    raise UnableToDownload, "Error loading: #{uri}. Could not resolve host." if addresses.empty?

    if addresses.any? { |ip| OutboundAddress.blocked_ip?(ip) }
      raise UnableToDownload, "Error loading: #{uri}. Can't download from a private address."
    end

    addresses.first.to_s
  end

  # A Location nothing can follow is the server's failure, not ours: it ends
  # the download like any other refusal. Addressable only repairs encoding
  # (spaces, non-ASCII); the result must still be a URI Net::HTTP can dial,
  # since Addressable alone accepts hosts such as "[not-an-ip".
  def redirect_uri(uri, location)
    URI.join(uri.to_s, location)
  rescue URI::Error
    begin
      URI(Addressable::URI.join(uri.to_s, location).normalize.to_s)
    rescue Addressable::URI::InvalidURIError, URI::Error, ArgumentError
      raise UnableToDownload, "Error loading: #{uri}. Invalid redirect."
    end
  end

  def parse_uri(url)
    URI(url)
  rescue URI::Error
    Addressable::URI.parse(url).normalize
  end

  # Unvalidated (internal) downloads only: redirects are followed by the
  # middleware, unpinned, as before.
  def conn(validate: Docuseal.multitenant?)
    Faraday.new do |faraday|
      faraday.response :follow_redirects, callback: lambda { |_, new_env|
        validate_uri!(new_env[:url]) if validate
      }
    end
  end
end
