# frozen_string_literal: true

module TemplateBuilderSessions
  class Create
    DEFAULT_EXPIRES_IN = 2.hours
    MAX_EXPIRES_IN = 24.hours

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

      ActiveRecord::Base.transaction do
        template = find_or_create_template
        preferences = builder_preferences(template)

        template.update!(preferences:)
      end

      WebhookUrls.enqueue_events(template, 'template.created') if created_template?
      SearchEntries.enqueue_reindex(template)

      template
    end

    private

    attr_reader :user, :attrs, :ability

    def find_or_create_template
      if attrs[:template_id].present?
        find_existing_template
      elsif attrs[:clone_template_id].present?
        @created_template = true

        clone_template
      else
        @created_template = true
        Templates::CreateFromApi.call(template_attrs, user:)
      end
    end

    def find_existing_template
      template = Template.accessible_by(ability, :read).find(attrs[:template_id])

      raise CanCan::AccessDenied.new(nil, :update, template) unless ability.can?(:update, template)

      template
    end

    def template_attrs
      attrs.slice(:name, :external_id, :application_key, :folder_name, :documents, :submitters, :fields)
    end

    def clone_template
      original_template = Template.accessible_by(ability, :read).find(attrs[:clone_template_id])

      ActiveRecord::Associations::Preloader.new(
        records: [original_template],
        associations: [{ schema_documents: :preview_images_attachments }]
      ).call

      cloned_template = Templates::Clone.call(
        original_template,
        author: user,
        name: attrs[:name],
        external_id: attrs[:external_id].presence || attrs[:application_key],
        folder_name: attrs[:folder_name]
      )

      cloned_template.source = :api
      cloned_template.save!

      if attrs[:documents].present?
        replace_cloned_documents(cloned_template, original_template)
      else
        Templates::CloneAttachments.call(template: cloned_template, original_template:)
      end

      Templates.maybe_assign_access(cloned_template)
      cloned_template.save!

      cloned_template
    end

    def replace_cloned_documents(cloned_template, original_template)
      files = Templates::CreateFromApi.build_uploaded_files(attrs[:documents])
      documents = Templates::ReplaceAttachments.call(cloned_template, { files: }, extract_fields: true)

      Templates::CloneAttachments.call(template: cloned_template, original_template:,
                                       excluded_attachment_uuids: documents.map(&:uuid))
    end

    def builder_preferences(template)
      preferences = template.preferences || {}

      preferences.merge(
        'embed_builder' => {
          'origin' => EmbedOrigins.normalize(attrs[:embed_origin]),
          'external_id' => attrs[:external_id].presence || attrs[:application_key].presence,
          'metadata' => attrs[:metadata].presence,
          'expires_at' => expires_at.iso8601
        }.compact_blank
      )
    end

    def expires_at
      minutes = attrs[:expires_in_minutes].presence&.to_i
      duration = minutes ? minutes.minutes : DEFAULT_EXPIRES_IN

      Time.current + [duration, MAX_EXPIRES_IN].min
    end

    def created_template?
      @created_template == true
    end
  end
end
