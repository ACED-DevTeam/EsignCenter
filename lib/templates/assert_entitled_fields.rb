# frozen_string_literal: true

module Templates
  # Server-side check for the two field-level features the builder can switch
  # on: conditional logic (paid-only) and formulas (hidden for everyone).
  # Called wherever incoming fields are about to be assigned to a template;
  # never at signing time — an existing template keeps evaluating its
  # conditions after a downgrade (D43).
  #
  # Accepts the builder/API field arrays as permitted params or plain hashes;
  # schema items (document-level conditions) can be passed in the same array.
  module AssertEntitledFields
    module_function

    def call(account, fields)
      items = Array.wrap(fields).map { |field| normalize(field) }

      Entitlements.require!(account, :formulas) if items.any? { |field| formula?(field) }
      Entitlements.require!(account, :conditional_logic) if items.any? { |field| field[:conditions].present? }

      true
    end

    def formula?(field)
      field[:formula].present? || field.dig(:preferences, :formula).present?
    end

    def normalize(field)
      hash = field.respond_to?(:to_unsafe_h) ? field.to_unsafe_h : field.to_h

      hash.with_indifferent_access
    end
  end
end
