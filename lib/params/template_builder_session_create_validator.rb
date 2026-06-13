# frozen_string_literal: true

module Params
  class TemplateBuilderSessionCreateValidator < BaseValidator
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
      validate_template_payload if params[:documents].present?

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
