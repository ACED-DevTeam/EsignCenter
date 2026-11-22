# frozen_string_literal: true

module MarketingAdmin
  module Social
    # Outbound HTTP for the social adapters: short timeouts, a ceiling on how
    # many requests one check may make, and error messages with every
    # credential taken out before they are stored or shown.
    #
    # Credentials travel in request HEADERS, never in the address, so a
    # failed request's URL — which is what ends up in logs and error messages
    # — has nothing in it worth stealing. `scrub` is the second line of
    # defence for whatever an API chooses to echo back.
    class Http
      TIMEOUT_SECONDS = 8
      MESSAGE_LIMIT = 240

      def initialize(budget:, secrets: [])
        @left = budget
        @secrets = secrets.compact_blank
      end

      def get(url, params: {}, headers: {})
        request(:get, url, params, headers)
      end

      def post(url, body: {}, headers: {})
        request(:post, url, body, headers)
      end

      # Remove anything that looks like a credential from a message.
      def scrub(message)
        text = message.to_s.gsub(/(access_token|refresh_token|client_secret|key|token)=[^&\s"']+/i, '\1=…')
        text = text.gsub(/\b(EAA|IGAA|IGQ)[A-Za-z0-9_-]{10,}/, '[token]')
                   .gsub(/\bya29\.[A-Za-z0-9._-]{10,}/, '[token]')
                   .gsub(%r{\b1//[A-Za-z0-9_-]{10,}}, '[token]')
                   .gsub(/\bAIza[A-Za-z0-9_-]{20,}/, '[key]')
        @secrets.each { |secret| text = text.gsub(secret, '[secret]') if secret.length >= 8 }

        text.squish.first(MESSAGE_LIMIT)
      end

      private

      def request(verb, url, payload, headers)
        raise Error, 'Made too many requests in one check' if @left <= 0

        @left -= 1

        parse(connection.public_send(verb, url, payload, headers))
      rescue Faraday::Error => e
        raise Error, scrub("Could not reach the app (#{e.class.name.demodulize})")
      end

      def connection
        @connection ||= Faraday.new(request: { timeout: TIMEOUT_SECONDS, open_timeout: TIMEOUT_SECONDS })
      end

      # Google and Meta both put a readable reason in body.error.message.
      def parse(response)
        data = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          nil
        end
        problem = data['error'] if data.is_a?(Hash)

        if !response.success? || problem
          reason = problem.is_a?(Hash) ? problem['message'] : problem

          raise Error.new(scrub("#{response.status}: #{reason.presence || 'the app refused the request'}"),
                          status: response.status)
        end

        raise Error, "#{response.status}: the app sent something unreadable" if data.nil?

        data
      end
    end
  end
end
