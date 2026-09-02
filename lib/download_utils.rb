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

  module_function

  # infra-keep: every caller that fetches a user-supplied URL passes validate: true explicitly;
  # the default only decides the behaviour for internal callers.
  #
  # With `max_bytes` the body is streamed and the download is abandoned as
  # soon as it exceeds the bound, so a large file never sits in memory whole;
  # the returned response carries the collected body as usual.
  def call(url, validate: Docuseal.multitenant?, max_bytes: nil)
    uri = begin
      URI(url)
    rescue URI::Error
      Addressable::URI.parse(url).normalize
    end

    validate_uri!(uri) if validate

    resp = max_bytes ? bounded_get(uri, validate:, max_bytes:) : conn(validate:).get(uri)

    raise UnableToDownload, "Error loading: #{uri}" if resp.status >= 400

    resp
  end

  def bounded_get(uri, validate:, max_bytes:)
    body = +''

    resp = conn(validate:).get(uri) do |req|
      req.options.on_data = proc do |chunk, received_bytes, env|
        # A redirect's own body streams through here too before the
        # follow-redirects middleware moves on; only the final answer counts.
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

  def conn(validate: Docuseal.multitenant?)
    Faraday.new do |faraday|
      faraday.response :follow_redirects, callback: lambda { |_, new_env|
        validate_uri!(new_env[:url]) if validate
      }
    end
  end
end
