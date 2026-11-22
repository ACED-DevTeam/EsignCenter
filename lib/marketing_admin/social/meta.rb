# frozen_string_literal: true

module MarketingAdmin
  module Social
    # What the Facebook and Instagram adapters share: one long-lived Page
    # token covers the Page and the Instagram business account linked to it.
    module Meta
      HOST = 'https://graph.facebook.com'
      VERSION = 'v25.0'
      BASE = "#{HOST}/#{VERSION}".freeze
      TOKEN_ENV = 'MARKETING_META_PAGE_TOKEN'

      module_function

      def http(budget)
        Http.new(budget:, secrets: [Social.env(TOKEN_ENV)])
      end

      # In a header, never in the address (see Http).
      def headers
        { 'Authorization' => "Bearer #{Social.env(TOKEN_ENV)}" }
      end
    end
  end
end
