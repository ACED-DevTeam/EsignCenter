# frozen_string_literal: true

module Templates
  # Server-side check for the two field-level features the builder can switch
  # on: conditional logic (paid-only) and formulas (hidden for everyone).
  # Called wherever incoming fields are about to be assigned to a template;
  # never at signing time — an existing template keeps evaluating its
  # conditions after a downgrade (D43).
  #
  # With a `baseline` (the persisted template being updated) only what the
  # incoming set INTRODUCES is refused: a condition or formula already carried
  # by the same item (same uuid, equal content) may stay or be removed, so a
  # downgraded account can keep saving a template it built while paid. Create
  # paths — API create, every clone — pass no baseline: everything counts as
  # new, so a free account cannot multiply a conditional template and nobody
  # can clone one with a formula field.
  #
  # Accepts the builder/API field arrays as permitted params or plain hashes;
  # schema items (document-level conditions) go in `schema:` or in the same
  # array.
  module AssertEntitledFields
    module_function

    def call(account, fields, schema: nil, baseline: nil)
      items = normalize_all([*fields, *schema])
      persisted = baseline ? normalize_all([*baseline.fields, *baseline.schema]).index_by { |item| item_key(item) } : {}

      if items.any? { |item| introduces_formula?(item, persisted[item_key(item)]) }
        Entitlements.require!(account, :formulas)
      end

      if items.any? { |item| introduces_conditions?(item, persisted[item_key(item)]) }
        Entitlements.require!(account, :conditional_logic)
      end

      true
    end

    def introduces_formula?(item, persisted_item)
      formula = formula_of(item)

      formula.present? && formula != formula_of(persisted_item)
    end

    def introduces_conditions?(item, persisted_item)
      item['conditions'].present? && item['conditions'] != persisted_item&.dig('conditions')
    end

    def formula_of(item)
      return if item.nil?

      item['formula'].presence || item.dig('preferences', 'formula').presence
    end

    # Fields carry `uuid`; schema items carry `attachment_uuid`.
    def item_key(item)
      item['uuid'].presence || item['attachment_uuid']
    end

    def normalize_all(items)
      Array.wrap(items).map { |item| normalize(item) }
    end

    def normalize(item)
      hash = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item.to_h

      hash.deep_stringify_keys
    end
  end
end
