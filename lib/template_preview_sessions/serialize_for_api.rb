# frozen_string_literal: true

module TemplatePreviewSessions
  module SerializeForApi
    module_function

    def call(session)
      {
        id: session.token,
        token: session.token,
        template_id: session.template.id,
        name: session.template.name,
        preview_src: routes.embed_template_preview_url(token: session.token, **Docuseal.default_url_options),
        embed_origin: session.origin,
        expires_at: session.expires_at.utc.iso8601
      }
    end

    def routes
      Rails.application.routes.url_helpers
    end
  end
end
