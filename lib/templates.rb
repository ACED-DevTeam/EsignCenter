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

  # A document still marked converting this long after its conversion last
  # showed progress (the job starting, or the PDF it swapped in half-way)
  # has lost its job (a dead-set entry, a container killed mid-run): it is
  # treated as failed so the user gets the failed card and its Remove
  # button instead of a template blocked forever.
  CONVERSION_STALE_AFTER = 30.minutes

  # A converting attachment the schema does not list is normally one the
  # user removed (the timed-out card's Remove button splices the schema
  # only; the attachment and its job stay) and must not block sending. But
  # the builder's add-document flow lists the item CLIENT-SIDE after the
  # upload response and saves the schema on its next autosave, so a brand
  # new unlisted attachment is still on its way in: it keeps blocking (and
  # its job keeps running) for this long after the attachment record was
  # created. The record's own timestamp is the clock, not the blob's: the
  # job swaps a fresh PDF blob into the attachment half-way through, and a
  # document the user already removed must not start blocking again then.
  CONVERSION_UNLISTED_GRACE = 2.minutes

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
  # converting blocks while the schema lists it, or while it is younger than
  # CONVERSION_UNLISTED_GRACE (still being listed by the builder); a failed
  # one (including a stale conversion) blocks while the schema lists it (the
  # builder's "remove document" drops it from the schema, not from storage).
  # A failed document outranks a converting one: it needs the user's action.
  def documents_status(template)
    flagged = flagged_documents(template)

    return if flagged.empty?

    schema_uuids = schema_attachment_uuids(template)

    return 'failed' if flagged.any? { |d| conversion_failed?(d) && schema_uuids.include?(d.uuid) }

    if flagged.any? { |d| converting?(d) && (schema_uuids.include?(d.uuid) || within_unlisted_grace?(d)) }
      return 'converting'
    end

    nil
  end

  def schema_attachment_uuids(template)
    template.schema.to_a.map { |item| item['attachment_uuid'] || item[:attachment_uuid] }
  end

  def schema_lists?(template, document)
    schema_attachment_uuids(template).include?(document.uuid)
  end

  def within_unlisted_grace?(document)
    document.created_at > CONVERSION_UNLISTED_GRACE.ago
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

  # Measured from the last sign of progress: the moment the job first ran
  # (`conversion_started_at`, stamped by ConvertWordDocumentJob — queue wait
  # and slot wait do not count) or the blob's own timestamp (the Word upload,
  # or the PDF the job swapped in half-way through), whichever is later.
  def stale_conversion?(document)
    return false if document.metadata['converting'].blank?

    conversion_progress_at(document) < CONVERSION_STALE_AFTER.ago
  end

  def conversion_progress_at(document)
    [conversion_started_at(document), document.blob.created_at].compact.max
  end

  # The stamp the job wrote, or nil when it is missing or unreadable: a
  # value that cannot be parsed (an out-of-range date raises, junk parses to
  # nil) must never break readiness checks, so the blob timestamp decides.
  def conversion_started_at(document)
    value = document.metadata['conversion_started_at'].presence

    return if value.nil?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError => e
    ErrorReport.warning(e, attachment_uuid: document.uuid, conversion_started_at: value.to_s)

    nil
  end

  # Re-derives every schema item's `converting` / `conversion_failed` flag
  # from its attachment's metadata. The builder autosaves the whole schema
  # without those keys (they are not permitted params, and the client is not
  # trusted with them), so each save would otherwise drop the placeholder and
  # stop the polling after a reload.
  #
  # The `pending_fields` marker (fields a conversion found, not yet merged
  # into template.fields by any builder) is only ever ARMED by the job: the
  # persisted schema item decides whether it stays — a builder that
  # autosaves with an older copy of the schema must not lose the fields —
  # and it is dropped as soon as a field area claims the attachment (the
  # builder merged them). The one thing a client can say is an explicit
  # `false` (the "Remove" choice), which drops it; a client `true` counts
  # for nothing, so a builder still carrying the marker after "Keep" can
  # never re-arm it once the user deletes the merged fields.
  def refresh_conversion_flags(template)
    flagged = flagged_documents(template).index_by(&:uuid)
    persisted_pending = persisted_pending_fields_uuids(template)
    claimed = claimed_attachment_uuids(template)

    template.schema = template.schema.to_a.map do |item|
      item = item.to_h.stringify_keys.except('converting', 'conversion_failed')
      document = flagged[item['attachment_uuid']]

      item['converting'] = true if document && converting?(document)
      item['conversion_failed'] = true if document && conversion_failed?(document)

      refresh_pending_fields(item, persisted_pending:, claimed:)
    end
  end

  def refresh_pending_fields(item, persisted_pending:, claimed:)
    uuid = item['attachment_uuid']
    removed = item.key?('pending_fields') &&
              ActiveModel::Type::Boolean.new.cast(item['pending_fields']) == false

    item.delete('pending_fields')

    return item if removed || claimed.include?(uuid)

    item['pending_fields'] = true if persisted_pending.include?(uuid)

    item
  end

  def persisted_pending_fields_uuids(template)
    template.schema_in_database.to_a.filter_map do |item|
      item = item.to_h.stringify_keys

      item['attachment_uuid'] if item['pending_fields']
    end
  end

  def claimed_attachment_uuids(template)
    template.fields.to_a.flat_map do |field|
      Array(field['areas'] || field[:areas]).map { |area| area['attachment_uuid'] || area[:attachment_uuid] }
    end.compact.uniq
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
