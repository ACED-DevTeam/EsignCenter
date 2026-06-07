# frozen_string_literal: true

module SigningSessions
  module SerializeForApi
    module_function

    def call(submission, params: {})
      submitters = Submitter.where(submission_id: submission.id)
                            .preload(documents_attachments: :blob, attachments_attachments: :blob)
                            .order(:id)
      submitter_json = submitters.map do |submitter|
        Submitters::SerializeForApi.call(submitter, with_documents: false, with_urls: true, params:)
      end

      {
        id: submission.id,
        submission_id: submission.id,
        template_id: submission.template_id,
        external_id: submission.preferences['signing_session_external_id'],
        status: status(submission, submitters),
        completed_at: completed_at(submitters)&.as_json,
        embed_src: submitter_json.first&.dig('embed_src'),
        submitter_id: submitter_json.first&.dig('id'),
        submitters: submitter_json,
        documents_url: routes.api_submission_documents_url(submission_id: submission.id,
                                                           **Docuseal.default_url_options),
        status_url: routes.api_signing_session_url(submission.id, **Docuseal.default_url_options),
        created_at: submission.created_at.as_json,
        updated_at: submission.updated_at.as_json
      }.compact
    end

    def completed_at(submitters)
      return unless submitters.present? && submitters.all?(&:completed_at?)

      submitters.max_by(&:completed_at).completed_at
    end

    def status(submission, submitters)
      return 'completed' if completed_at(submitters)

      Submissions::SerializeForApi.build_status(submission, submitters)
    end

    def routes
      Rails.application.routes.url_helpers
    end
  end
end
