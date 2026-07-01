# frozen_string_literal: true

module SigningSessions
  class Create
    def self.call(...)
      new(...).call
    end

    def initialize(user:, attrs:, ability: nil)
      @user = user
      @attrs = attrs.to_h.with_indifferent_access
      @ability = ability || Ability.new(user)
    end

    def call
      template = nil
      submission = nil

      ActiveRecord::Base.transaction do
        template = find_or_create_template
        submission = create_submission(template)
        apply_embed_preferences(submission)
      end

      WebhookUrls.enqueue_events(template, 'template.created') if created_template?
      WebhookUrls.enqueue_events(submission, 'submission.created')
      Submissions.send_signature_requests([submission])
      SearchEntries.enqueue_reindex([template, submission])

      submission
    end

    private

    attr_reader :user, :attrs, :ability

    def find_or_create_template
      if attrs[:template_id].present?
        Template.accessible_by(ability, :read).find(attrs[:template_id])
      else
        @created_template = true
        Templates::CreateFromApi.call(template_attrs, user:)
      end
    end

    def create_submission(template)
      if template.fields.blank?
        Rollbar.warning("Template does not contain fields: #{template.id}") if defined?(Rollbar)

        raise Submissions::CreateFromSubmitters::BaseError, 'Template does not contain fields'
      end

      submissions_attrs, attachments =
        Submissions::NormalizeParamUtils.normalize_submissions_params!(
          [submission_attrs],
          template,
          purpose: :api
        )

      submissions = Submissions.create_from_submitters(
        template:,
        user:,
        source: :embed,
        submitters_order: attrs[:submitters_order] || attrs[:order] || 'preserved',
        submissions_attrs:,
        params: submission_preferences
      )

      submitters = submissions.flat_map(&:submitters)

      Submissions::NormalizeParamUtils.save_default_value_attachments!(attachments, submitters)

      submissions.first || raise(Submissions::CreateFromSubmitters::BaseError, 'Unable to create signing session')
    end

    def template_attrs
      attrs.slice(:name, :external_id, :application_key, :folder_name, :documents, :submitters, :fields)
    end

    def submission_attrs
      {
        name: attrs[:name],
        expire_at: attrs[:expire_at],
        variables: attrs[:variables] || {},
        submitters: submitter_attrs
      }.compact_blank.with_indifferent_access
    end

    def submitter_attrs
      Array.wrap(attrs[:submitters]).map do |submitter|
        item = submitter.to_h.with_indifferent_access
        item[:role] ||= item[:name] if attrs[:documents].present?
        item[:metadata] = (item[:metadata] || {}).merge(signing_session_metadata).compact_blank
        item
      end
    end

    def signing_session_metadata
      (attrs[:metadata] || {}).merge(
        'signing_session_external_id' => attrs[:external_id].presence || attrs[:application_key].presence
      ).compact_blank
    end

    def submission_preferences
      preferences = {
        'send_email' => attrs.key?(:send_email) ? attrs[:send_email] : false,
        'send_sms' => attrs.key?(:send_sms) ? attrs[:send_sms] : false
      }

      %i[completed_redirect_url reply_to bcc_completed message].each do |key|
        preferences[key.to_s] = attrs[key] if attrs[key].present?
      end

      preferences.with_indifferent_access
    end

    def apply_embed_preferences(submission)
      origins = EmbedOrigins.normalize_all(attrs[:embed_origin], attrs[:embed_origins])

      preferences = (submission.preferences || {}).merge(
        'embed_origin' => origins.first,
        'embed_origins' => origins,
        'signing_session_external_id' => attrs[:external_id].presence || attrs[:application_key]
      ).compact_blank

      preferences['metadata'] = attrs[:metadata] if attrs[:metadata].present?

      submission.update!(preferences:)
    end

    def created_template?
      @created_template == true
    end
  end
end
