# frozen_string_literal: true

module Params
  class SigningSessionCreateValidator < BaseValidator
    LOCAL_HTTP_HOSTS = ['localhost', '127.0.0.1', '::1'].freeze

    def call
      required(params, :embed_origin)
      required(params, :submitters)
      type(params, :template_id, Integer)
      type(params, :embed_origin, String)
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
      uri = URI.parse(params[:embed_origin].to_s)

      return if valid_origin_uri?(uri) && secure_or_local_origin?(uri)

      raise_invalid_embed_origin
    rescue URI::InvalidURIError
      raise_invalid_embed_origin
    end

    def valid_origin_uri?(uri)
      uri.is_a?(URI::HTTP) &&
        uri.hostname.present? &&
        uri.userinfo.blank? &&
        uri.path.in?(['', '/']) &&
        uri.query.blank? &&
        uri.fragment.blank?
    end

    def secure_or_local_origin?(uri)
      return true if uri.scheme == 'https'

      uri.scheme == 'http' && LOCAL_HTTP_HOSTS.include?(uri.hostname.downcase)
    end

    def raise_invalid_embed_origin
      raise_error('embed_origin must be an https origin like https://app.example.com, ' \
                  'or http://localhost for local development')
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
