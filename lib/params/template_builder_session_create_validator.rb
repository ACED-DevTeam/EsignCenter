# frozen_string_literal: true

module Params
  class TemplateBuilderSessionCreateValidator < BaseValidator
    # The builder ships every custom field to the browser in a data attribute,
    # so the list is capped to keep the embed page a sane size.
    MAX_CUSTOM_FIELDS = 200
    MAX_CUSTOM_FIELDS_BYTESIZE = 8 * 1024
    MAX_CUSTOM_FIELD_STRING_LENGTH = 120
    CUSTOM_FIELD_STRING_KEYS = %i[type role title].freeze
    CUSTOM_FIELD_LENGTH_LIMITED_KEYS = %i[name role title].freeze

    # The field types the EMBEDDED builder can actually place. Derived from
    # app/javascript/template_builder/field_type.vue: its icon list minus the
    # types it never offers (heading, datenow, strikethrough) minus the ones
    # gated behind flags the embed page leaves off — `data-with-payment="false"`
    # in app/views/embed_template_builder/show.html.erb, and withPhone /
    # withVerification / withKba, which the page never sets and which default to
    # false/null in builder.vue. A palette entry the builder cannot render is a
    # broken entry, so it is rejected here instead.
    CUSTOM_FIELD_TYPES = %w[text signature initials date number image checkbox
                            multiple file radio select cells stamp].freeze

    def call
      required(params, :embed_origin)
      type(params, :template_id, Integer)
      type(params, :clone_template_id, Integer)
      type(params, :embed_origin, String)
      type(params, :external_id, String)
      type(params, :application_key, String)
      type(params, :metadata, Hash)
      type(params, :expires_in_minutes, Integer)

      validate_embed_origin
      validate_expires_in_minutes
      validate_template_source
      validate_custom_fields
      validate_template_payload if params[:documents].present?

      true
    end

    private

    def validate_custom_fields
      custom_fields = params[:custom_fields]

      return if custom_fields.blank?

      return raise_error('custom_fields must be an Array') unless custom_fields.is_a?(Array)

      if custom_fields.size > MAX_CUSTOM_FIELDS
        return raise_error("custom_fields must contain #{MAX_CUSTOM_FIELDS} items or fewer")
      end

      # `in_path_each` skips nil entries, so a `[null]` array would slip past
      # unnoticed and reach the normalizer. Reject it here instead.
      return raise_error('custom_fields item must be an Object') if custom_fields.any?(&:nil?)

      if serialized_bytesize(custom_fields) > MAX_CUSTOM_FIELDS_BYTESIZE
        return raise_error("custom_fields must be #{MAX_CUSTOM_FIELDS_BYTESIZE} bytes or fewer")
      end

      in_path_each(params, [:custom_fields]) do |custom_field|
        validate_custom_field(custom_field)
      end
    end

    def validate_custom_field(custom_field)
      unless custom_field.is_a?(Hash) || custom_field.is_a?(ActionController::Parameters)
        return raise_error('custom_fields item must be an Object')
      end

      required(custom_field, :name)
      type(custom_field, :name, String)

      CUSTOM_FIELD_STRING_KEYS.each { |key| type(custom_field, key, String) }

      validate_custom_field_lengths(custom_field)
      validate_custom_field_type(custom_field)
    end

    # A blank/absent type is fine — TemplateBuilderSessions::Create defaults it
    # to 'text'. A type the builder cannot place is not.
    def validate_custom_field_type(custom_field)
      return if custom_field[:type].blank?
      return if CUSTOM_FIELD_TYPES.include?(custom_field[:type])

      raise_error("type must be one of #{CUSTOM_FIELD_TYPES.join(', ')}")
    end

    def serialized_bytesize(custom_fields)
      custom_fields.map { |item| item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item }.to_json.bytesize
    end

    def validate_custom_field_lengths(custom_field)
      CUSTOM_FIELD_LENGTH_LIMITED_KEYS.each do |key|
        next if custom_field[key].to_s.length <= MAX_CUSTOM_FIELD_STRING_LENGTH

        raise_error("#{key} must be #{MAX_CUSTOM_FIELD_STRING_LENGTH} characters or fewer")
      end
    end

    def validate_embed_origin
      EmbedOrigins.validate!(params[:embed_origin])
    end

    def validate_expires_in_minutes
      return if params[:expires_in_minutes].blank?
      return if params[:expires_in_minutes].positive?

      raise_error('expires_in_minutes must be greater than 0')
    end

    def validate_template_source
      source_count = %i[template_id clone_template_id documents].count { |key| params[key].present? }

      # Zero sources is allowed: the builder opens on a blank template and the
      # user adds documents inside it ("start from scratch"). One source is the
      # normal case. Only reject conflicting multi-source requests.
      return if source_count <= 1
      return if params[:clone_template_id].present? && params[:documents].present? && params[:template_id].blank?

      raise_error('Provide at most one of template_id, clone_template_id, or documents')
    end

    def validate_template_payload
      Params::TemplateCreateValidator.call(params)
    end
  end
end
