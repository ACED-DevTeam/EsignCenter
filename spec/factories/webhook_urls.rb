# frozen_string_literal: true

FactoryBot.define do
  factory :webhook_url do
    account
    sequence(:url) { |number| "https://example.com/webhooks/#{number}" }
  end
end
