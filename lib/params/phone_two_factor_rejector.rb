# frozen_string_literal: true

module Params
  # Phone (SMS) 2FA is hidden for everyone in v1. Any request that asks for it
  # is refused with 422 before anything is stored. "Asks for it" follows the
  # Rails boolean cast: true, 'true', 'TRUE', 1, '1', 't', 'on', 'yes' and any
  # other non-blank value that is not an explicit false form count as a
  # request; nil, blank strings and the explicit false forms (false, 'false',
  # 'FALSE', 0, '0', 'f', 'off') are ignored — and never stored either.
  #
  # Only the places that can switch 2FA on are inspected: the top-level
  # params, each `submission` / `submissions` / `submitters` entry, and the
  # `preferences` hash of any of those. Free-form data (`metadata`, `values`,
  # `fields`, message bodies, external ids) is the customer's own and is
  # never read — a CRM storing `require_phone_2fa` in its metadata is not
  # asking for anything.
  module PhoneTwoFactorRejector
    ERROR_MESSAGE = 'Phone (SMS) verification is not available. Use require_email_2fa instead.'

    FLAG = 'require_phone_2fa'
    SUBMISSION_KEYS = %w[submission submissions].freeze

    module_function

    def call(params)
      check_object(params)

      SUBMISSION_KEYS.each do |key|
        entries(params, key).each do |submission|
          check_object(submission)
          entries(submission, 'submitters').each { |submitter| check_object(submitter) }
        end
      end

      entries(params, 'submitters').each { |submitter| check_object(submitter) }

      true
    end

    # Checks one structural object (top level, a submission, a submitter) and
    # its own `preferences` hash — nothing deeper.
    def check_object(object)
      return unless hash_like?(object)

      refuse! if requested?(fetch(object, FLAG))

      preferences = fetch(object, 'preferences')

      refuse! if hash_like?(preferences) && requested?(fetch(preferences, FLAG))
    end

    def entries(object, key)
      return [] unless hash_like?(object)

      value = fetch(object, key)

      value.is_a?(Array) ? value : [value]
    end

    def fetch(object, key)
      object[key].nil? ? object[key.to_sym] : object[key]
    end

    def hash_like?(object)
      object.respond_to?(:each_pair) && object.respond_to?(:[])
    end

    def requested?(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end

    def refuse!
      raise BaseValidator::InvalidParameterError, ERROR_MESSAGE
    end
  end
end
