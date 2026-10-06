# frozen_string_literal: true

module TemplateBuilderSessions
  class Create
    DEFAULT_EXPIRES_IN = 2.hours
    MAX_EXPIRES_IN = 24.hours
    CUSTOM_FIELD_KEYS = %w[name type role title].freeze
    DEFAULT_CUSTOM_FIELD_TYPE = 'text'

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
          'custom_fields' => custom_fields,
          'expires_at' => expires_at.iso8601
        }.compact_blank
      )
    end

    # Optional builder-only field palette handed to the embedded builder Vue app.
    # `compact_blank` above drops the key entirely when none are given, so a
    # session created without `custom_fields` keeps the exact preferences shape
    # it had before this option existed.
    #
    # Every entry is rebuilt here rather than passed through: the builder keys
    # its palette on `field.uuid` (fields.vue renders `:key="field.uuid"` and
    # reorders by `data-uuid`), so a uuid is generated server-side for each
    # entry, the type falls back to a plain text field, and the caller's strings
    # are hard-capped. Params::TemplateBuilderSessionCreateValidator has already
    # rejected anything outside these bounds; this is the floor under it.
    def custom_fields
      Array(attrs[:custom_fields]).filter_map do |custom_field|
        next unless custom_field.respond_to?(:to_h)

        normalize_custom_field(custom_field.to_h.with_indifferent_access.slice(*CUSTOM_FIELD_KEYS))
      end.presence
    end

    def normalize_custom_field(entry)
      name = truncate_custom_field_value(entry[:name])

      return if name.blank?

      {
        'uuid' => SecureRandom.uuid,
        'name' => name,
        'type' => custom_field_type(entry[:type]),
        'role' => truncate_custom_field_value(entry[:role]),
        'title' => truncate_custom_field_value(entry[:title])
      }.compact_blank
    end

    def custom_field_type(type)
      type = type.to_s.strip
      allowed = Params::TemplateBuilderSessionCreateValidator::CUSTOM_FIELD_TYPES

      allowed.include?(type) ? type : DEFAULT_CUSTOM_FIELD_TYPE
    end

    def truncate_custom_field_value(value)
      value.to_s.strip.first(Params::TemplateBuilderSessionCreateValidator::MAX_CUSTOM_FIELD_STRING_LENGTH).presence
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
