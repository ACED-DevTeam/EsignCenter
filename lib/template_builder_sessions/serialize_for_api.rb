# frozen_string_literal: true

module TemplateBuilderSessions
  module SerializeForApi
    module_function

    def call(template)
      {
        id: template.id,
        template_id: template.id,
        name: template.name,
        external_id: template.external_id,
        status: template.fields.present? ? 'ready' : 'needs_fields',
        builder_src: routes.embed_template_builder_url(token: signed_token(template), **Docuseal.default_url_options),
        template: Templates::SerializeForApi.call(template),
        signing_session_url: routes.api_signing_sessions_url(**Docuseal.default_url_options),
        created_at: template.created_at.as_json,
        updated_at: template.updated_at.as_json,
        expires_at: template.preferences.dig('embed_builder', 'expires_at')
      }.compact
    end

    def routes
      Rails.application.routes.url_helpers
    end

    def signed_token(template)
      expires_at = Time.zone.parse(template.preferences.dig('embed_builder', 'expires_at').to_s)
      expires_in = [expires_at - Time.current, 1.second].max

      template.signed_id(purpose: :embed_builder, expires_in:)
    rescue ArgumentError, TypeError
      template.signed_id(purpose: :embed_builder, expires_in: TemplateBuilderSessions::Create::DEFAULT_EXPIRES_IN)
    end
  end
end
