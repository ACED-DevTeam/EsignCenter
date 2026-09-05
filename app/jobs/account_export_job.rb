# frozen_string_literal: true

# Builds the account export zip (Session 8 phase D).
#
# The same discipline as ConvertWordDocumentJob, and for the same reason: this
# is heavy work over a customer's whole document store, so it runs on the
# low-concurrency `documents` queue, it has a hard wall-clock cap, and it
# never holds a whole file in memory (Accounts::ExportArchive streams every
# blob chunk by chunk into a Tempfile).
#
# `retry: 2` rather than the application default of five: an export that has
# failed twice is almost never going to succeed on the third try, and the
# customer is better served by a failure they can see — with a Retry button on
# the page and an email saying so — than by half an hour of silent retries.
#
# The row is the state machine. Whatever happens, the job leaves it saying
# something true: ready with a file attached, or failed with the error on it.
# A run that dies without either (a worker killed mid-build) leaves it
# `running`, and the nightly sweep fails it Accounts::Exports::STALE_AFTER
# after the worker CLAIMED it, so the account's door is not blocked for ever.
# The sweep and this job take the row's lock for that handover: see `finalize!`.
class AccountExportJob
  include Sidekiq::Job

  sidekiq_options queue: :documents, retry: 2

  # Longer than any export we expect and short enough that a wedged run is
  # noticed the same day.
  HARD_TIMEOUT = 30.minutes

  # How much of the error text is kept on the row. It is shown to the
  # customer, so it is a sentence, not a stack.
  MAX_ERROR = 500

  # Sidekiq gave up. The row must not stay "running" — the page would poll for
  # ever and no new export could be requested.
  sidekiq_retries_exhausted do |job, exception|
    AccountExportJob.new.fail_after_retries(job['args'].first, exception)
  end

  # A failure that is worth trying again is RAISED, so Sidekiq retries it and
  # `sidekiq_retries_exhausted` writes the ending. The one failure that is not
  # worth trying again is the wall-clock cap: retrying a build that ran for
  # half an hour just spends another hour to say the same thing, so it is
  # marked failed on the spot.
  def perform(export_id)
    export = claim(export_id)

    return if export.nil?

    begin
      Timeout.timeout(HARD_TIMEOUT.to_i, Timeout::Error, timeout_message) do
        build!(export)
      end
    rescue Timeout::Error => e
      fail!(export, e)
    end

    nil
  end

  def fail_after_retries(export_id, exception)
    export = AccountExport.find_by(id: export_id)

    return if export.nil? || !export.in_progress?

    fail!(export, exception)
  end

  private

  def timeout_message
    "the export took longer than #{HARD_TIMEOUT.inspect} and was stopped"
  end

  # Only an export that is still owed work is built. A row that is already
  # ready (a duplicate enqueue) or expired is left exactly as it is.
  #
  # `started_at` is THIS ATTEMPT's clock and is rewritten every time the row is
  # claimed (review 8, X2). It is what the nightly recovery measures staleness
  # against, so it has to mean "a worker took this on at this moment" — on a
  # Sidekiq retry hours after the first try, the second attempt is a live build
  # however long ago the first one started.
  def claim(export_id)
    export = AccountExport.find_by(id: export_id)

    return nil if export.nil? || !export.in_progress?

    export.update!(status: AccountExport::RUNNING, started_at: Time.current)

    export
  end

  # The upload happens OUTSIDE the row lock and the attach inside it (see
  # `finalize!`): the bucket write is the slow part of a build and a row lock
  # held across it is a row lock held for minutes.
  #
  # NOTHING IS UPLOADED THAT THE ROW CANNOT NAME (review 8, W2). The blob row
  # is created and written onto the export BEFORE the first byte goes to the
  # bucket, so a worker killed anywhere between here and `finalize!` leaves a
  # file that `fail!` and the nightly sweeps can still find and delete. Without
  # it, a Timeout::Error during the upload of a large account's zip left a copy
  # of the customer's entire account in the bucket for ever, referenced by
  # nothing.
  def build!(export)
    summary = nil
    blob = nil

    Tempfile.create(['account-export', '.zip'], binmode: true) do |file|
      summary = Accounts::ExportArchive.call(export, file.path)

      file.rewind
      blob = ActiveStorage::Blob.create_after_unfurling!(io: file, filename: filename_for(export),
                                                         content_type: 'application/zip')
      stage!(export, blob)

      file.rewind
      blob.upload_without_unfurling(file)
    end

    # Somebody else finished with this row while we were building. Nothing
    # further is owed — not the READY row, and not the email.
    return nil unless finalize!(export, blob, summary)

    # The mail is part of the SUCCESS PATH and has its own rescue (review 2,
    # M12). It used to be a bare `deliver_later!` after the row was committed
    # READY: an enqueue that raised took the whole job down, and the retry's
    # `claim` then refused the READY row and returned quietly — so a broker
    # wobble lost the promised email for ever, with nothing anywhere saying
    # so. Now the outcome is written on the row: `notified` is false when the
    # message could not be handed over, and the page prints a line saying the
    # export is ready but the email did not go out.
    export.update!(summary: summary.merge('notified' => notify_ready(export)))

    nil
  end

  # THE LAST TWO STEPS OF A BUILD ARE ONE STEP, TAKEN UNDER THE ROW'S LOCK
  # (review 8, X2).
  #
  # The nightly stale-export recovery is looking at this same row and will fail
  # it if the attempt started longer ago than Accounts::Exports::STALE_AFTER.
  # Without the lock the two interleave: recovery reads `running`, this worker
  # attaches the zip and says READY, and recovery then deletes that zip and
  # overwrites the row with `failed` — a finished export destroyed and a
  # customer told their build died. So both sides take the lock and both re-read
  # the row inside it (Accounts::Retention.fail_stale_export!).
  #
  # Losing the race is not an error. The row was declared dead by the sweep, the
  # day's budget was handed back and the customer may already have asked for
  # another one, so this archive is thrown away — storage first, the same way
  # round as everywhere else (H6) — rather than resurrecting a row somebody else
  # has finished with.
  def finalize!(export, blob, summary)
    finished = false

    export.with_lock do
      next unless export.status == AccountExport::RUNNING

      export.archive.attach(blob)
      # The fresh summary replaces the staged pointer as it is written: the
      # blob is attached now, so `export.archive` is what finds it from here on.
      export.update!(status: AccountExport::READY, finished_at: Time.current,
                     expires_at: Accounts::Exports::TTL.from_now, error: nil,
                     summary: summary.except(AccountExport::STAGED_BLOB_ID))

      finished = true
    end

    unless finished
      discard_blob(blob, export)
      unstage!(export, blob)
    end

    finished
  end

  # Names the blob on the row before a byte of it is uploaded, and clears out
  # anything a PREVIOUS attempt staged and never finished — a Sidekiq retry
  # builds a second zip, and the first one is abandoned the moment this row
  # points at the second. Storage first, as everywhere else (H6).
  def stage!(export, blob)
    previous = export.staged_blob

    discard_blob(previous, export) if previous && previous.id != blob.id

    export.stage_blob!(blob)
  end

  # Only ever clears a pointer that still names the blob just dealt with: a row
  # that has moved on to another attempt keeps its own.
  def unstage!(export, blob)
    export.reload

    export.unstage_blob! if export.summary[AccountExport::STAGED_BLOB_ID].to_i == blob.id
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def notify_ready(export)
    AccountMailer.export_ready(export).deliver_later!

    true
  rescue StandardError => e
    ErrorReport.error(e, account_id: export.account_id, account_export_id: export.id)

    false
  end

  def filename_for(export)
    stamp = Time.current.utc.strftime('%Y%m%d')

    "esigncenter-export-#{export.account_id}-#{stamp}.zip"
  end

  # Failing is a real outcome, not an incident: the row says so, the person
  # who asked is told, and the error is reported once. Deliberately NO
  # OperatorAlert — an export that could not be built wakes nobody up.
  def fail!(export, error)
    export.reload

    return unless export.in_progress?

    message = "#{error.class}: #{error.message}".first(MAX_ERROR)

    # Storage first, rows second (review 2, H6). A half-written archive is
    # still a copy of the customer's whole account, and `archive.purge` would
    # take the row that names it before the object — so a storage hiccup here
    # would leave that copy in the bucket for ever with nothing able to find
    # it again. If the file will not go, the row keeps pointing at it and the
    # nightly sweep tries again.
    discard_archive(export)

    export.update!(status: AccountExport::FAILED, finished_at: Time.current, error: message)

    # The day's budget is only spent by exports that produced something
    # (review 2, Opus #7).
    Accounts::Exports.refund!(export)

    ErrorReport.error(error, account_id: export.account_id, account_export_id: export.id)

    AccountMailer.export_failed(export).deliver_later!

    nil
  rescue StandardError => e
    # The failure path must never be what takes the job down.
    ErrorReport.error(e, account_export_id: export&.id)

    nil
  end

  # Never `archive.purge`: see `fail!`. A StorageFailure is swallowed here on
  # purpose — the row is about to be marked failed either way, and the sweep
  # (Accounts::Retention.purge_failed_export_files!) owns the retry.
  #
  # BOTH halves of a build product go: the archive if one was ever attached,
  # and the zip an attempt was uploading when it died, which is attached to
  # nothing and would otherwise sit in the bucket for ever (review 8, W2).
  def discard_archive(export)
    discard_blob(export.archive.blob, export) if export.archive.attached?

    discard_staged_blob(export)
  end

  def discard_staged_blob(export)
    blob = export.staged_blob

    return if blob.nil?

    discard_blob(blob, export)
    unstage!(export, blob)
  end

  def discard_blob(blob, export)
    Accounts::Purge.purge_blob_storage_first!(blob, account_id: export.account_id)
  rescue Accounts::Purge::StorageFailure => e
    ErrorReport.error(e, account_id: export.account_id, account_export_id: export.id)
  end
end
