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
      persisted = baseline ? normalize_all([*baseline.fields, *baseline.schema]) : []

      Entitlements.require!(account, :formulas) if introduces?(items, persisted, :formula)
      Entitlements.require!(account, :conditional_logic) if introduces?(items, persisted, :conditions)

      true
    end

    # The incoming set introduces the feature when any carrying item differs
    # from the persisted item of the same identity — or when identities cannot
    # be trusted: a template does not validate uuid uniqueness, so two incoming
    # items reusing one legacy uuid, or more carrying items than the baseline
    # had, are treated as new rather than matched against the same row twice.
    def introduces?(items, persisted, kind)
      carrying = items.select { |item| content_of(item, kind).present? }
      persisted_carrying = persisted.select { |item| content_of(item, kind).present? }

      return false if carrying.empty?
      return true if carrying.size > persisted_carrying.size
      return true if carrying.map { |item| item_key(item) }.tally.values.any? { |count| count > 1 }

      persisted_by_key = persisted.index_by { |item| item_key(item) }

      carrying.any? { |item| content_of(item, kind) != content_of(persisted_by_key[item_key(item)], kind) }
    end

    def content_of(item, kind)
      return if item.nil?
      return item['conditions'].presence if kind == :conditions

      item['formula'].presence || item.dig('preferences', 'formula').presence
    end

    # Fields carry `uuid`; schema items carry `attachment_uuid`. Namespaced so
    # a field and a document can never share an identity.
    def item_key(item)
      item['uuid'].present? ? "field:#{item['uuid']}" : "schema:#{item['attachment_uuid']}"
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
