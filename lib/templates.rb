# frozen_string_literal: true

module Templates
  COLOR_REGEXP = /\A(#(?:[0-9a-f]{3}|[0-9a-f]{6})|[a-z]+)\z/i

  TEMPLATE_BUILDER_FIELDS = %i[id author_id folder_id external_id name slug
                               schema fields submitters variables_schema preferences
                               shared_link source archived_at created_at updated_at].freeze

  EXPIRATION_DURATIONS = {
    one_day: 1.day,
    two_days: 2.days,
    three_days: 3.days,
    four_days: 4.days,
    five_days: 5.days,
    six_days: 6.days,
    seven_days: 7.days,
    eight_days: 8.days,
    nine_days: 9.days,
    ten_days: 10.days,
    two_weeks: 14.days,
    three_weeks: 21.days,
    four_weeks: 28.days,
    one_month: 1.month,
    two_months: 2.months,
    three_months: 3.months
  }.with_indifferent_access.freeze

  # A document still marked converting this long after its blob was stored
  # has lost its job (a dead-set entry, a container killed mid-run): it is
  # treated as failed so the user gets the failed card and its Remove
  # button instead of a template blocked forever.
  CONVERSION_STALE_AFTER = 30.minutes

  # Raised wherever a submission would be built from a template that still
  # has a Word document converting (or one that failed to convert): the PDF
  # pipeline needs a PDF behind every schema entry. `status` is 'converting'
  # or 'failed'; the message is the user-facing one for that state.
  class DocumentsNotReady < StandardError
    attr_reader :status

    def initialize(status)
      @status = status

      super(I18n.t(status == 'failed' ? 'document_conversion_failed' : 'documents_still_converting'))
    end
  end

  module_function

  # nil when every document is ready, otherwise 'converting' or 'failed'.
  # The attachments' own blob metadata decides — the schema flags are only a
  # cache the builder reads (see refresh_conversion_flags). A document still
  # converting anywhere on the template blocks, whether or not the schema
  # lists it yet; a failed one (including a stale conversion) blocks while
  # the schema still lists it (the builder's "remove document" drops it from
  # the schema, not from storage). A failed document outranks a converting
  # one: it needs the user's action.
  def documents_status(template)
    flagged = flagged_documents(template)

    return if flagged.empty?

    schema_uuids = template.schema.to_a.map { |item| item['attachment_uuid'] || item[:attachment_uuid] }

    return 'failed' if flagged.any? { |d| conversion_failed?(d) && schema_uuids.include?(d.uuid) }
    return 'converting' if flagged.any? { |d| converting?(d) }

    nil
  end

  def flagged_documents(template)
    template.documents.preload(:blob).select do |document|
      document.metadata['converting'] || document.metadata['conversion_failed']
    end
  end

  def converting?(document)
    document.metadata['converting'].present? && !stale_conversion?(document)
  end

  def conversion_failed?(document)
    document.metadata['conversion_failed'].present? || stale_conversion?(document)
  end

  # The blob's own timestamp is the last sign of progress: the Word upload,
  # or the PDF the job swapped in half-way through.
  def stale_conversion?(document)
    document.metadata['converting'].present? && document.blob.created_at < CONVERSION_STALE_AFTER.ago
  end

  # Re-derives every schema item's `converting` / `conversion_failed` flag
  # from its attachment's metadata. The builder autosaves the whole schema
  # without those keys (they are not permitted params, and the client is not
  # trusted with them), so each save would otherwise drop the placeholder and
  # stop the polling after a reload.
  def refresh_conversion_flags(template)
    flagged = flagged_documents(template).index_by(&:uuid)

    template.schema = template.schema.to_a.map do |item|
      item = item.to_h.stringify_keys.except('converting', 'conversion_failed')
      document = flagged[item['attachment_uuid']]

      item['converting'] = true if document && converting?(document)
      item['conversion_failed'] = true if document && conversion_failed?(document)

      item
    end
  end

  def documents_ready?(template)
    documents_status(template).nil?
  end

  def assert_documents_ready!(template)
    status = documents_status(template)

    raise DocumentsNotReady, status if status

    true
  end

  def build_field_areas_index(fields)
    hash = {}

    fields.each do |field|
      (field['areas'] || []).each do |area|
        hash[area['attachment_uuid']] ||= {}
        acc = (hash[area['attachment_uuid']][area['page']] ||= [])

        acc << [area, field]
      end
    end

    hash
  end

  def maybe_assign_access(_template)
    nil
  end

  def search(current_user, templates, keyword)
    if Docuseal.fulltext_search?
      fulltext_search(current_user, templates, keyword)
    else
      plain_search(templates, keyword)
    end
  end

  def plain_search(templates, keyword)
    return templates if keyword.blank?

    sanitized = ActiveRecord::Base.sanitize_sql_like(keyword.downcase)

    templates.where(Template.arel_table[:name].lower.matches("%#{sanitized}%"))
  end

  def fulltext_search(current_user, templates, keyword)
    return templates if keyword.blank?

    templates.where(
      id: SearchEntry.where(record_type: 'Template')
                     .where(account_id: [current_user.account_id,
                                         current_user.account.linked_account_account&.account_id].compact)
                     .where(*SearchEntries.build_tsquery(keyword))
                     .select(:record_id)
    )
  end

  def filter_undefined_submitters(template_submitters)
    template_submitters.to_a.select do |item|
      item['invite_by_uuid'].blank? && item['optional_invite_by_uuid'].blank? &&
        item['invite_via_field_uuid'].blank? &&
        item['linked_to_uuid'].blank? && item['is_requester'].blank? && item['email'].blank?
    end
  end

  def build_default_expire_at(template)
    default_expire_at_duration = template.preferences['default_expire_at_duration'].presence
    default_expire_at = template.preferences['default_expire_at'].presence

    return if default_expire_at_duration.blank?

    if default_expire_at_duration == 'specified_date' && default_expire_at.present?
      Time.zone.parse(default_expire_at)
    elsif EXPIRATION_DURATIONS[default_expire_at_duration]
      Time.current + EXPIRATION_DURATIONS[default_expire_at_duration]
    end
  end

  def serialize_for_builder(template)
    data = template.as_json(only: TEMPLATE_BUILDER_FIELDS)

    data['documents'] = template.schema_documents.preload(:blob, { preview_images_attachments: :blob }).as_json(
      only: %i[id uuid],
      methods: %i[metadata signed_key],
      include: { preview_images: { only: %i[id], methods: %i[url metadata filename] } }
    )

    data
  end
end
