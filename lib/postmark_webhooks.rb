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

  # How many parked message ids one sweep walks. See sweep_pending!.
  SWEEP_BATCH = 500
  # ...and how many of the FAILED ones, which are kept rather than dropped and
  # would otherwise fill the batch on their own and starve every newer row
  # behind them (review 2, N4).
  FAILED_BATCH = 50
  # How long a failed replay is left alone before the sweep tries it again.
  # The sweep is hourly, so in practice this only stops a manual or catch-up
  # run from spending the failed batch on rows tried a minute ago.
  RETRY_INTERVAL = 1.hour
  # How many failed replays before the operator is told (sweep_pending!).
  MAX_REPLAY_ATTEMPTS = 5
  # ...and how many before we accept the row will never land. A day of hourly
  # retries: past that it is a bug to fix from the alert, not a row to keep
  # retrying for ever (review 2, N4).
  MAX_ATTEMPTS = 24
  # How much of a replay failure is kept on the row.
  MAX_ERROR = 500

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

  # AN EVENT THIS ENDPOINT ANSWERS 200 IS AN EVENT WE HAVE KEPT (review 8, D8).
  #
  # A webhook can arrive BEFORE the send row it belongs to. The send row is
  # written by an observer that runs after the message has been handed over
  # (lib/action_mailer_events_observer.rb), and Postmark can be back with a
  # bounce before that observer's INSERT commits — so "no matching send event"
  # is an ordering, not a mistake, and answering 200 and forgetting it lost
  # real bounces for ever.
  #
  # The two designs on the table were "answer 500 so Postmark retries" and
  # "park it". Retrying loses the event when the send row takes longer than
  # Postmark's retry schedule and makes a healthy endpoint look broken, so the
  # event is PARKED (PendingEmailEvent), keyed by the provider's message uuid,
  # and attributed the moment the send row lands. The message is only ever
  # parked when it carries a uuid we could match later; a webhook for a
  # message this application never sent (no metadata at all) is still ignored.
  #
  # Parking is followed by an immediate re-check, because the send row can
  # commit in the instant between the lookup above and the parking INSERT:
  # without it, that one row would sit parked until the hourly sweep.
  def record!(record)
    type = event_type(record)

    return { ignored: true } unless type

    send_event = attributed_send(record)

    return park!(record) unless send_event

    persist!(record, send_event, type)

    { recorded: true }
  rescue DuplicateEvent
    { duplicate: true }
  end

  # Keeps the webhook until its send row exists. A retry of a webhook already
  # parked is the same event and lands on the unique provider event key, so it
  # parks once however many times Postmark tries.
  def park!(record)
    uuid = message_uuid(record)

    if uuid.blank?
      Rails.logger.info('Postmark webhook ignored: no message uuid to attribute it by')

      return { ignored: true }
    end

    PendingEmailEvent.create!(provider_message_id: uuid, provider_event_key: provider_event_key(record), record:)

    # The send row may have landed while we were parking it.
    attribute_pending!(uuid)

    { parked: true }
  rescue ActiveRecord::RecordNotUnique
    { parked: true }
  end

  # Replays every webhook parked against a message uuid, in arrival order.
  # Called by the observer as soon as the send rows for that uuid are written,
  # and by the hourly sweep for anything left behind. A parked event whose send
  # row STILL cannot be found is left where it is; one that is recorded, or
  # that turns out to be a duplicate of an event already recorded, is dropped.
  #
  # Nothing here may take its caller down: the observer is inside the delivery
  # path of a message that has already been sent, and the sweep walks many
  # messages. A replay that fails is reported and left parked for the next one.
  # A replay that RAISES is a different thing from one that finds no send row,
  # and the row now says which it was (review 2, M8). A failure — the timeline
  # write, the sending-pause write — is recorded on the row with its message
  # and a count, so the sweep keeps retrying it, the three-day clock does not
  # apply to it, and the operator is told once it has failed enough times —
  # and told again if it is finally dropped at MAX_ATTEMPTS, because Postmark
  # has already been answered 200 for these, so deleting one loses a real
  # bounce or complaint for good.
  def attribute_pending!(uuid)
    PendingEmailEvent.for_message(uuid).each do |pending|
      record = pending.record
      type = event_type(record)
      send_event = type && attributed_send(record)

      next if send_event.nil?

      begin
        persist!(record, send_event, type)
      rescue DuplicateEvent
        nil
      end

      pending.destroy
    rescue StandardError => e
      ErrorReport.error(e)

      note_attribution_error!(pending, e)
    end
  end

  # Kept, counted and named. `update_columns` on purpose: the row is being
  # written from inside a rescue, and validations or callbacks failing here
  # would swallow the very thing we are recording.
  def note_attribution_error!(pending, error)
    pending.update_columns(attempts: pending.attempts.to_i + 1,
                           attribution_error: "#{error.class}: #{error.message}".first(MAX_ERROR),
                           last_attempted_at: Time.current,
                           updated_at: Time.current)
  rescue StandardError => e
    ErrorReport.error(e)
  end

  # The hourly sweep (HousekeepingJob): replay what can now be attributed, drop
  # what has waited longer than a send row can take, and say what is stuck.
  # Answers what it did, because a rising `dropped` count is the shape of a
  # real bug — a mailer whose send rows are not being written at all — and a
  # rising `errored` count is the shape of another: a replay that keeps
  # throwing.
  #
  # Bounded on purpose, and bounded SEPARATELY for the two kinds of row
  # (review 2, N4). The walk used to visit every parked message id on every
  # tick, which with a three-day wait is two queries per parked message per
  # hour for ever; a plain `order(:id).limit` fixed that and introduced the
  # opposite failure, because failed rows are deliberately never dropped: with
  # SWEEP_BATCH of them sitting at the head of the table, every tick retried
  # only those and no newer row was ever reached — it would age out at three
  # days without the sweep having tried it once. So the batch is taken from
  # the rows that have never failed, oldest first, plus a small FAILED_BATCH
  # of the least-recently-tried failures.
  #
  # `dropped` is counted BEFORE `pending`, because the deletion is what
  # decides how many are left — the other way round the summary counted the
  # rows it was about to delete as still waiting (review 2, L8). It counts
  # both kinds of deletion: a callback that waited three days for a send row
  # that never came, and one whose replay failed MAX_ATTEMPTS times.
  def sweep_pending!(now: Time.current)
    # Taken before the walk, so the alert below can tell a row that has just
    # crossed the threshold from one that was over it an hour ago.
    already_stuck = PendingEmailEvent.failed.where(attempts: MAX_REPLAY_ATTEMPTS..).ids

    sweep_message_ids(now).each { |uuid| attribute_pending!(uuid) }

    dropped = PendingEmailEvent.expired(now).delete_all + drop_exhausted_replays!
    errored = PendingEmailEvent.failed.count

    maybe_alert_stuck_replays!(already_stuck)

    { pending: PendingEmailEvent.count, dropped:, errored: }
  end

  # The message ids this tick walks: the head of the queue that has never
  # failed, plus a small share of the failures, least recently tried first so
  # many stuck rows take turns rather than the lowest ids taking every tick.
  def sweep_message_ids(now)
    fresh = PendingEmailEvent.where(attribution_error: nil)
                             .order(:id).limit(SWEEP_BATCH).pluck(:provider_message_id)

    retries = PendingEmailEvent.failed
                               .where('last_attempted_at IS NULL OR last_attempted_at <= ?', now - RETRY_INTERVAL)
                               .order(:last_attempted_at).limit(FAILED_BATCH).pluck(:provider_message_id)

    (fresh + retries).uniq
  end

  # One alert per row, when its replay has failed enough times to be more than
  # a blip — sent on the sweep that takes it OVER the threshold and not again
  # (review 2, N3). These rows are retried by every tick and never expire, so
  # alerting on the state rather than on the crossing meant one poisoned row
  # mailed the operator every hour for ever, which is how the next real alert
  # gets ignored. It names the rows so an operator can go and look at them; it
  # never raises, because the sweep has other work after it.
  def maybe_alert_stuck_replays!(already_alerted = [])
    stuck = PendingEmailEvent.failed.where(attempts: MAX_REPLAY_ATTEMPTS...MAX_ATTEMPTS)
                             .where.not(id: already_alerted).order(:id).limit(20).to_a

    return if stuck.empty?

    OperatorAlert.deliver(
      subject: "#{stuck.size} Postmark webhook#{'s' if stuck.size > 1} cannot be replayed",
      body: "These parked Postmark callbacks have failed to replay #{MAX_REPLAY_ATTEMPTS} times or more. " \
            "They are kept and every hourly sweep tries again, until #{MAX_ATTEMPTS} attempts, when they " \
            "are dropped and you are told again.\n\n#{alert_lines(stuck)}"
    )
  rescue StandardError => e
    ErrorReport.error(e)
  end

  # The end of the line for a replay that has never worked. Postmark was
  # answered 200 for these, so the deletion is a real loss and is announced as
  # one — but a row that has failed a full day of retries is a bug to fix from
  # the alert, and keeping it for ever costs every later row its place in the
  # batch. Answers how many it deleted.
  def drop_exhausted_replays!
    exhausted = PendingEmailEvent.failed.where(attempts: MAX_ATTEMPTS..).order(:id).limit(20).to_a

    return 0 if exhausted.empty?

    announce_exhausted_replays(exhausted)

    PendingEmailEvent.where(id: exhausted.map(&:id)).delete_all
  end

  def announce_exhausted_replays(exhausted)
    OperatorAlert.deliver(
      subject: "#{exhausted.size} Postmark webhook#{'s' if exhausted.size > 1} dropped after failing to replay",
      body: "These parked Postmark callbacks failed to replay #{MAX_ATTEMPTS} times and have been DELETED. " \
            'Postmark was answered 200 for them, so whatever they carried — a bounce, a complaint — is ' \
            "gone.\n\n#{alert_lines(exhausted)}"
    )
  rescue StandardError => e
    ErrorReport.error(e)
  end

  # One line per row, named so an operator can go and look at them.
  def alert_lines(rows)
    rows.map do |pending|
      "pending_email_events ##{pending.id} message #{pending.provider_message_id} " \
        "attempts #{pending.attempts}: #{pending.attribution_error}"
    end.join("\n")
  end

  # The uuid our own mailer stamped on the message (ApplicationMailer#
  # set_message_uuid), which is what ties a webhook to its send rows.
  def message_uuid(record)
    metadata = record['Metadata']

    return unless metadata.is_a?(Hash)

    metadata['message-uuid'].presence || metadata['message_uuid'].presence
  end

  def attributed_send(record)
    uuid = message_uuid(record)

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
      SendingPause.evaluate!(event.account, event:) if SendingPause.pause_trigger?(type)

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
