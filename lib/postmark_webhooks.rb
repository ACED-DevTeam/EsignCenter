# frozen_string_literal: true

require 'ipaddr'

module PostmarkWebhooks
  DEFAULT_IPS = %w[3.134.147.250 50.31.156.6 50.31.156.77 18.217.206.57].freeze
  EVENT_TYPES = { 'Delivery' => 'delivery', 'SpamComplaint' => 'complaint', 'Open' => 'open',
                  'Click' => 'click', 'SubscriptionChange' => 'subscription_change' }.freeze
  HARD_BOUNCES = %w[HardBounce BadEmailAddress Blocked DnsError SpamNotification].freeze
  SUPPRESSIONS = %w[ManuallyDeactivated Unsubscribe].freeze
  # Clicks already have an app-owned tracking link; temporary delays are not
  # signer failures. Both still get EmailEvent rows, without timeline rows.
  TIMELINE_TYPES = { 'permanent_bounce' => 'bounce_email', 'complaint' => 'complaint_email',
                     'open' => 'open_email' }.freeze
  DATA_FIELDS = %w[MessageID RecordType Type TypeCode Description Details MessageStream ServerID Inactive
                   OriginalLink FirstOpen UserAgent SuppressSending].freeze
  GEO_FIELDS = %w[CountryISOCode Country RegionISOCode Region City Zip Coords IP].freeze

  class DuplicateEvent < StandardError; end

  module_function

  def configured?
    ENV['POSTMARK_WEBHOOK_USERNAME'].present? && ENV['POSTMARK_WEBHOOK_PASSWORD'].present?
  end

  def authenticated?(username, password)
    # Evaluate both comparisons, including when the username is wrong.
    user_ok = ActiveSupport::SecurityUtils.secure_compare(username.to_s, ENV['POSTMARK_WEBHOOK_USERNAME'].to_s)
    pass_ok = ActiveSupport::SecurityUtils.secure_compare(password.to_s, ENV['POSTMARK_WEBHOOK_PASSWORD'].to_s)

    user_ok & pass_ok
  end

  def allowed_ip?(address)
    ranges = ENV['POSTMARK_WEBHOOK_IPS'].presence&.split(',') || DEFAULT_IPS
    ip = IPAddr.new(address)

    ranges.map { |range| IPAddr.new(range.strip) }.any? { |range| range.include?(ip) }
  rescue IPAddr::Error
    false
  end

  def record!(record)
    type = event_type(record)

    return { ignored: true } unless type

    send_event = attributed_send(record)

    unless send_event
      Rails.logger.info('Postmark webhook ignored: no matching send event')

      return { ignored: true }
    end

    persist!(record, send_event, type)

    { recorded: true }
  rescue DuplicateEvent
    { duplicate: true }
  end

  def attributed_send(record)
    metadata = record['Metadata']

    return unless metadata.is_a?(Hash)

    uuid = metadata['message-uuid'].presence || metadata['message_uuid'].presence

    return if uuid.blank?

    sends = EmailEvent.where(message_id: uuid, event_type: 'send').order(:id)

    sends.find_by('LOWER(email) = ?', recipient(record).downcase) || sends.first
  end

  def recipient(record)
    (record['Recipient'].presence || record['Email']).to_s
  end

  def event_type(record)
    return EVENT_TYPES[record['RecordType']] unless record['RecordType'] == 'Bounce'
    return 'suppressed' if SUPPRESSIONS.include?(record['Type'])

    record['Inactive'] == true || HARD_BOUNCES.include?(record['Type']) ? 'permanent_bounce' : 'soft_bounce'
  end

  def timestamp(record)
    record.values_at('BouncedAt', 'DeliveredAt', 'ReceivedAt', 'ChangedAt').compact.first
  end

  def event_datetime(record)
    Time.zone.parse(timestamp(record).to_s) || Time.current
  rescue ArgumentError, TypeError
    Time.current
  end

  def provider_event_key(record)
    [record['RecordType'], record['ID'] || record['MessageID'], recipient(record).downcase, timestamp(record)].join(':')
  end

  # The event, timeline and abuse pause WRITE are atomic. A failure rolls all
  # of them back so Postmark retries the automatic stop as well as the event.
  # Quotas.with_creation_lock joins this transaction (advisory, then row lock).
  def persist!(record, send_event, type)
    EmailEvent.transaction(requires_new: true) do
      event = create_event!(record, send_event, type)
      project_timeline(event)
      SendingPause.evaluate!(event.account, event:) if %w[complaint permanent_bounce].include?(type)

      event
    end
  end

  def create_event!(record, send_event, type)
    data = event_data(record)
    data['recipient_mismatch'] = true unless send_event.email.casecmp?(recipient(record))

    EmailEvent.create!(
      **send_event.attributes.slice('account_id', 'emailable_type', 'emailable_id', 'tag', 'message_id'),
      event_type: type, email: recipient(record), event_datetime: event_datetime(record),
      provider_event_key: provider_event_key(record), data:
    )
  rescue ActiveRecord::RecordNotUnique
    # Only the email INSERT means duplicate. A uniqueness failure while
    # writing an abuse flag must roll back and return 500, never acknowledge.
    raise DuplicateEvent
  end

  def event_data(record)
    data = record.slice(*DATA_FIELDS).to_h { |key, value| [key.underscore, bounded_scalar(value)] }
    data['provider_message_id'] = data.delete('message_id')

    if record['Geo'].is_a?(Hash) && %w[Open Click].include?(record['RecordType'])
      data['geo'] = record['Geo'].slice(*GEO_FIELDS).transform_values { |value| bounded_scalar(value) }
    end

    data.compact
  end

  def bounded_scalar(value)
    case value
    when String then value.first(500)
    when Numeric, true, false then value
    end
  end

  def project_timeline(event)
    type = TIMELINE_TYPES[event.event_type]

    return unless type && event.emailable.is_a?(Submitter)
    return if event.data['recipient_mismatch']
    return unless event.emailable.email.to_s.casecmp?(event.email)

    SubmissionEvent.create!(submitter: event.emailable, event_type: type, event_timestamp: event.event_datetime,
                            data: event.data.slice('type', 'description').merge('email' => event.email))
  end
end
