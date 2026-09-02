# frozen_string_literal: true

module Params
  # Phone (SMS) 2FA is hidden for everyone in v1. Any request that asks for it
  # is refused with 422 before anything is stored. "Asks for it" follows the
  # Rails boolean cast: true, 'true', 'TRUE', 1, '1', 't', 'on', 'yes' and any
  # other non-blank value that is not an explicit false form count as a
  # request; nil, blank strings and the explicit false forms (false, 'false',
  # 'FALSE', 0, '0', 'f', 'off') are ignored — and never stored either.
  module PhoneTwoFactorRejector
    ERROR_MESSAGE = 'Phone (SMS) verification is not available. Use require_email_2fa instead.'

    module_function

    def call(value)
      each_pair(value) do |key, nested_value|
        if key.to_s == 'require_phone_2fa' && requested?(nested_value)
          raise BaseValidator::InvalidParameterError, ERROR_MESSAGE
        end

        call(nested_value)
      end

      Array(value).each { |nested_value| call(nested_value) } if value.is_a?(Array)

      true
    end

    def requested?(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end

    def each_pair(value, &)
      value.each_pair(&) if value.respond_to?(:each_pair)
    end
  end
end
