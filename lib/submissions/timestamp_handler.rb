# frozen_string_literal: true

module Submissions
  class TimestampHandler
    HASH_ALGORITHM = 'SHA256'
    TIMEOUT = 10

    # A timestamp authority that cannot be reached is a failed signature, never
    # a silently degraded one: the signing job raises, Sidekiq retries it and
    # Sentry sees the report. Before Session 4 this handler embedded a locally
    # generated time instead, which looked like a trusted timestamp but was not.
    class TimestampError < StandardError
      attr_reader :urls, :original_error

      def initialize(urls, original_error = nil)
        @urls = Array(urls)
        @original_error = original_error

        super("Timestamp authority request failed (#{@urls.join(', ')})" \
              "#{": #{original_error.class}: #{original_error.message}" if original_error}")
      end
    end

    attr_reader :tsa_url, :tsa_fallback_url

    def initialize(tsa_url:)
      @tsa_url, @tsa_fallback_url = tsa_url.split(',')
    end

    def finalize_objects(_signature_field, signature)
      signature.document.version = '2.0'

      signature[:Type] = :DocTimeStamp
      signature[:Filter] = :'Adobe.PPKLite'
      signature[:SubFilter] = :'ETSI.RFC3161'
    end

    def sign(io, byte_range)
      digest = message_digest(io, byte_range)
      last_error = nil

      urls.each do |url|
        return request_token(url, digest)
      rescue StandardError => e
        last_error = e
        Rails.logger.error(e)
      end

      raise_timestamp_error!(last_error)
    end

    def urls
      [tsa_url, tsa_fallback_url].compact_blank
    end

    def build_payload(digest)
      req = OpenSSL::Timestamp::Request.new
      req.algorithm = HASH_ALGORITHM
      req.message_imprint = digest

      req.to_der
    end

    private

    def message_digest(io, byte_range)
      digest = OpenSSL::Digest.new(HASH_ALGORITHM)

      io.pos = byte_range[0]
      digest << io.read(byte_range[1])
      io.pos = byte_range[2]
      digest << io.read(byte_range[3])

      digest.digest
    end

    def request_token(url, digest)
      uri = Addressable::URI.parse(url)

      conn = Faraday.new(uri.origin) do |c|
        c.options.read_timeout = TIMEOUT
        c.options.open_timeout = TIMEOUT
        c.request :authorization, :basic, uri.user, uri.password if uri.password.present?
      end

      response = conn.post(uri.request_uri, build_payload(digest), 'content-type' => 'application/timestamp-query')

      raise TimestampError, [url] if response.status != 200 || response.body.blank?

      OpenSSL::Timestamp::Response.new(response.body).token.to_der
    end

    # One report per signing attempt, however many URLs were tried.
    def raise_timestamp_error!(last_error)
      error = TimestampError.new(urls, last_error)

      ErrorReport.error(error)
      Rails.logger.error(error)

      raise error
    end
  end
end
