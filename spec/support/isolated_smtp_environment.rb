# frozen_string_literal: true

RSpec.shared_context 'with isolated SMTP environment' do
  let(:smtp_env_keys) do
    %w[
      EMAIL_DELIVERY_MODE
      POSTMARK_STREAM_PAID
      POSTMARK_STREAM_FREE
      POSTMARK_API_TOKEN
      SMTP_ADDRESS
      SMTP_AUTHENTICATION
      SMTP_DOMAIN
      SMTP_ENABLE_SSL
      SMTP_ENABLE_STARTTLS
      SMTP_ENABLE_TLS
      SMTP_FROM
      SMTP_OPEN_TIMEOUT
      SMTP_PASSWORD
      SMTP_PORT
      SMTP_READ_TIMEOUT
      SMTP_SSL_VERIFY
      SMTP_USERNAME
    ]
  end

  around do |example|
    original_values = smtp_env_keys.index_with { |key| ENV.fetch(key, nil) }
    smtp_env_keys.each { |key| ENV.delete(key) }

    example.run
  ensure
    original_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
