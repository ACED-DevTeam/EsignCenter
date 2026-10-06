# frozen_string_literal: true

# Turnstile has no environment bypass: the verification request is made even
# in the test suite. These stubs are the sanctioned way to answer it.
module TurnstileHelpers
  def stub_turnstile(success: true, error_codes: [])
    body = { success:, 'error-codes' => error_codes }

    stub_request(:post, Turnstile::VERIFY_URL)
      .to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_turnstile_outage
    stub_request(:post, Turnstile::VERIFY_URL).to_timeout
  end
end

RSpec.configure do |config|
  config.include TurnstileHelpers
end
