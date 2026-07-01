# frozen_string_literal: true

module Params
  class SigningSessionCreateValidator < BaseValidator
    def call
      required(params, :submitters)
      type(params, :template_id, Integer)
      type(params, :completed_redirect_url, String)
      type(params, :external_id, String)
      type(params, :application_key, String)
      type(params, :metadata, Hash)
      boolean(params, :send_email)
      boolean(params, :send_sms)

      validate_embed_origin
      validate_template_or_documents
      validate_template_payload if params[:documents].present?

      submission_params = params.to_unsafe_h.with_indifferent_access
      submission_params[:template_id] ||= 1

      Params::SubmissionCreateValidator.call(submission_params)

      true
    end

    private

    def validate_embed_origin
      origins = EmbedOrigins.collect(params[:embed_origin], params[:embed_origins])

      raise_error('embed_origin is required') if origins.blank?

      origins.each { |origin| EmbedOrigins.validate!(origin) }
    end

    def validate_template_or_documents
      return if params[:template_id].present? ^ params[:documents].present?

      raise_error('template_id or documents is required, but not both')
    end

    def validate_template_payload
      Params::TemplateCreateValidator.call(params)
    end
  end
end
