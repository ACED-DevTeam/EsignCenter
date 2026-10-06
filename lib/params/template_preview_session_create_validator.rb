# frozen_string_literal: true

module Params
  class TemplatePreviewSessionCreateValidator < BaseValidator
    # Dummy values ride inside the signed token, so they are capped hard: the
    # whole token travels in a URL and must stay well under the ~8 KB request
    # line every proxy and browser enforces. Signing and base64 inflate the
    # payload, so 4 KB of values is the ceiling.
    MAX_VALUES = 200
    MAX_VALUES_BYTESIZE = 4 * 1024

    def call
      required(params, :template_id)
      required(params, :embed_origin)
      type(params, :template_id, Integer)
      type(params, :embed_origin, String)
      type(params, :values, Hash)
      type(params, :expires_in_minutes, Integer)

      validate_embed_origin
      validate_expires_in_minutes
      validate_values

      true
    end

    private

    def validate_embed_origin
      EmbedOrigins.validate!(params[:embed_origin])
    end

    def validate_expires_in_minutes
      return if params[:expires_in_minutes].blank?
      return if params[:expires_in_minutes].positive?

      raise_error('expires_in_minutes must be greater than 0')
    end

    def validate_values
      values = params[:values]

      return if values.blank?

      values = values.to_unsafe_h if values.is_a?(ActionController::Parameters)

      return raise_error("values must contain #{MAX_VALUES} items or fewer") if values.size > MAX_VALUES

      values.each do |key, value|
        raise_error("values key #{key} must be a String") unless key.is_a?(String)
        raise_error("values.#{key} must be a String") unless value.is_a?(String)
      end

      return if values.to_json.bytesize <= MAX_VALUES_BYTESIZE

      raise_error("values must be #{MAX_VALUES_BYTESIZE} bytes or fewer")
    end
  end
end
