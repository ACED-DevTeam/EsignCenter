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
    AccountExportJob.new.fail_after_retries(job['args'].first, exception, jid: job['jid'])
  end

  # A failure that is worth trying again is RAISED, so Sidekiq retries it and
  # `sidekiq_retries_exhausted` writes the ending. The one failure that is not
  # worth trying again is the wall-clock cap: retrying a build that ran for
  # half an hour just spends another hour to say the same thing, so it is
  # marked failed on the spot.
  #
  # AND THE ROW IS HANDED BACK BEFORE THE RAISE (review 10, C-F1/C-F6). It
  # used to be left `running`, signed with this attempt's token, and the raise
  # was the whole of the failure handling. Sidekiq then retried — and the
  # retry is a new EXECUTION with a new token, so its `claim` found a running
  # row owned by somebody else, not yet stale, and returned nil. `perform`
  # returned nil, which Sidekiq reads as a job that SUCCEEDED: no further
  # retry, no `sidekiq_retries_exhausted`, and therefore nothing anywhere
  # writing an ending onto the row. The customer's export sat `running` for
  # up to two hours with the export door shut behind it and the day's budget
  # spent on nothing, until the nightly sweep failed it.
  #
  # So a retryable failure puts the row back to `pending` with no owner: the
  # retry claims it like any unclaimed row, and if every retry fails, the row
  # is still `pending` when `sidekiq_retries_exhausted` runs and that callback
  # writes the failure, refunds the day and reopens the door.
  #
  # A released row is then measured by the sweep's SHORT pending fuse rather
  # than the two-hour one — and that fuse runs from `created_at`, the moment
  # the customer asked, NOT from the release (`Retention.stale_export?`).
  # Usually that is the right answer: Sidekiq's backoff for `retry: 2` is
  # under two minutes, so a retry that never arrives reopens the door in
  # fifteen minutes rather than in a hundred and twenty. The edge it does not
  # cover, said plainly rather than papered over (review 10, Q5): a first
  # attempt that ran for more than fifteen minutes hands back a row that is
  # already stale, so a 04:30 sweep landing inside the retry's backoff gap
  # fails and refunds it and the retry's `claim` then returns nil. Narrow, and
  # the ending is honest — the customer sees "failed" with the day refunded
  # and the door open — which is why the fuse is left measuring from the
  # request rather than from the release.
  def perform(export_id)
    export = claim(export_id)

    return if export.nil?

    begin
      Timeout.timeout(HARD_TIMEOUT.to_i, Timeout::Error, timeout_message) do
        build!(export)
      end
    rescue Timeout::Error => e
      fail!(export, e)
    rescue StandardError
      release!(export)

      raise
    end

    nil
  end

  # Sidekiq has given up on this JOB, so this runs on a fresh object that owns
  # nothing (review 2, M7): the ownership check is made against the job id
  # instead, which every execution of that job signs with. A row that has since
  # been taken over by a different job is left to the execution building it.
  def fail_after_retries(export_id, exception, jid: nil)
    export = AccountExport.find_by(id: export_id)

    return if export.nil? || !export.in_progress?
    return if jid.present? && export.attempt_owner.present? && !export.attempt_owner.start_with?("#{jid}-")

    fail!(export, exception, check_owner: false)
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
  #
  # ONE EXECUTION, UNDER THE ROW'S LOCK, AND IT SIGNS THE CLAIM (review 8 D5,
  # corrected in review 2 M7).
  #
  # This used to be a read followed by an update with neither lock nor
  # signature: two workers handed the same export id both read `pending`, both
  # wrote `running`, and both built a zip over the same row, one deleting the
  # other's staged blob mid-upload. The signature fixed part of it — and then
  # signed with the `jid`, which Sidekiq reuses for every DELIVERY of one job.
  # Two deliveries of the same job (a broker hiccup, a manual requeue) both
  # matched the owner and both built, which is the same defect wearing the
  # fix's clothes. The token now names the EXECUTION: the jid, so the log still
  # says which job it was, plus a nonce made fresh in this object.
  #
  #   * a row nobody owns (pending) is claimed;
  #   * a running row owned by another execution is left alone — unless it is
  #     STALE by the nightly recovery's own predicate, which is the one
  #     definition of "that worker is dead" this code has. Without that a
  #     Sidekiq retry after a killed worker could never resume, and the row
  #     would wait for the sweep before anything could touch it;
  #   * a stale row is taken over, and from that moment the previous execution
  #     owns nothing: every step below re-checks ownership under the lock, so
  #     a zombie that wakes up cannot stage, upload or finish over the top of
  #     the execution that replaced it.
  #
  # A hand-driven run (`AccountExportJob.new.perform(id)` — the console, and
  # specs) has no `jid` and signs `inline-<nonce>`.
  def claim(export_id)
    export = AccountExport.find_by(id: export_id)

    return nil if export.nil?

    attempt = attempt_id
    claimed = false

    export.with_lock do
      next unless export.in_progress?
      next if claimed_by_a_live_execution?(export, attempt)

      export.update!(status: AccountExport::RUNNING, started_at: Time.current,
                     summary: export.summary.merge(AccountExport::ATTEMPT_KEY => attempt))

      claimed = true
    end

    claimed ? export : nil
  end

  def claimed_by_a_live_execution?(export, attempt)
    return false unless export.status == AccountExport::RUNNING
    return false if export.attempt_owner.blank? || export.attempt_owner == attempt

    !Accounts::Retention.stale_export?(export)
  end

  # Does this row still belong to this execution? Asked inside the lock by
  # every step that writes, because a takeover can have happened since the
  # claim.
  def owns?(export)
    export.attempt_owner == attempt_id
  end

  # Who this EXECUTION is. Sidekiq's job id is the same string across every
  # delivery and every retry of one job, so it cannot tell two executions
  # apart on its own; the nonce is what does.
  def attempt_id
    @attempt_id ||= "#{jid.presence || 'inline'}-#{SecureRandom.hex(8)}"
  end

  # The staged locator is committed before upload. Upload and finalization
  # each lock the export row so deletion and stale recovery can coordinate
  # with them, while archive assembly runs outside that lock.
  def build!(export)
    summary = nil
    blob = nil

    Tempfile.create(['account-export', '.zip'], binmode: true) do |file|
      summary = Accounts::ExportArchive.call(export, file.path)

      file.rewind
      blob = ActiveStorage::Blob.create_after_unfurling!(io: file, filename: filename_for(export),
                                                         content_type: 'application/zip')
      file.rewind
      unless stage!(export, blob) && upload!(export, blob, file)
        discard_blob(blob, export)

        return nil
      end
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
      next unless owns?(export)

      export.archive.attach(blob)
      # The fresh summary replaces the staged pointer as it is written: the
      # blob is attached now, so `export.archive` is what finds it from here on.
      export.update!(status: AccountExport::READY, finished_at: Time.current,
                     expires_at: Accounts::Exports::TTL.from_now, error: nil,
                     summary: summary.except(AccountExport::STAGED_BLOB_ID))

      finished = true
    end

    unstage!(export, blob) if !finished && discard_blob(blob, export)

    finished
  rescue ActiveRecord::RecordNotFound
    discard_blob(blob, export)

    false
  end

  # Names the blob on the row before a byte of it is uploaded, and clears out
  # anything a PREVIOUS attempt staged and never finished — a Sidekiq retry
  # builds a second zip, and the first one is abandoned the moment this row
  # points at the second. Storage first, as everywhere else (H6).
  def stage!(export, blob)
    export.with_lock do
      next false unless export.status == AccountExport::RUNNING
      next false unless owns?(export)

      previous = export.staged_blob
      if previous && previous.id != blob.id
        Accounts::Purge.purge_blob_storage_first!(previous, account_id: export.account_id)
      end

      export.stage_blob!(blob)
    end
  rescue ActiveRecord::RecordNotFound
    false
  end

  def upload!(export, blob, file)
    export.with_lock do
      next false unless export.status == AccountExport::RUNNING
      next false unless owns?(export)
      next false unless export.summary[AccountExport::STAGED_BLOB_ID] == blob.id

      blob.upload_without_unfurling(file)

      true
    end
  rescue ActiveRecord::RecordNotFound
    false
  end

  # Only ever clears a pointer that still names the blob just dealt with: a row
  # that has moved on to another attempt keeps its own.
  def unstage!(export, blob)
    export.reload

    return nil unless owns?(export)

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

  # Gives a claimed row back to whoever comes next, and only ever the row this
  # execution still owns (review 10, C-F1). A zombie whose build finally blows
  # up hours after the sweep replaced it must not put the LIVE execution's row
  # back to `pending` for a third worker to claim out from under it — hence the
  # same lock and the same ownership question every other write in this file
  # asks.
  #
  # The staged blob pointer is deliberately kept: the half-written zip is
  # still in the bucket, and the pointer is what the retry's `stage!` and the
  # nightly sweep use to find and delete it.
  def release!(export)
    export.with_lock do
      next unless export.status == AccountExport::RUNNING
      next unless owns?(export)

      export.update!(status: AccountExport::PENDING, started_at: nil,
                     summary: export.summary.except(AccountExport::ATTEMPT_KEY))
    end

    nil
  rescue StandardError => e
    # Best effort on purpose: the failure that is on its way up to Sidekiq is
    # the one that matters, and a row that could not be handed back is exactly
    # the row the nightly sweep exists for.
    ErrorReport.error(e, account_id: export.account_id, account_export_id: export.id)

    nil
  end

  # Failing is a real outcome, not an incident: the row says so, the person
  # who asked is told, and the error is reported once. Deliberately NO
  # OperatorAlert — an export that could not be built wakes nobody up.
  #
  # UNDER THE ROW'S LOCK, like every other write in this file (review 10,
  # C-F1). The decision used to be taken on a plain `reload` and the archive
  # deleted outside any lock, so it raced the nightly recovery and a
  # finishing worker over the same row — the one race `finalize!` was locked
  # to close, left open on the path that DELETES the file. Inside the lock the
  # row is re-read, the ownership question is asked of the exact execution
  # token, and the deletion and the status write are one step.
  def fail!(export, error, check_owner: true)
    message = "#{error.class}: #{error.message}".first(MAX_ERROR)
    failed = false

    export.with_lock do
      next unless export.in_progress?
      # A row taken over by a live execution is not this one's to fail: doing
      # so would delete the archive that execution is building.
      next if check_owner && !owns?(export)

      # Storage first, rows second (review 2, H6). A half-written archive is
      # still a copy of the customer's whole account, and `archive.purge`
      # would take the row that names it before the object — so a storage
      # hiccup here would leave that copy in the bucket for ever with nothing
      # able to find it again. If the file will not go, the row keeps pointing
      # at it and the nightly sweep tries again.
      discard_archive(export)

      export.update!(status: AccountExport::FAILED, finished_at: Time.current, error: message)

      failed = true
    end

    return nil unless failed

    # Outside the lock, for the reason Accounts::Retention.fail_stale_export!
    # gives: the day's counter is a different table, and a refund that fails
    # must not roll the failure — and therefore the reopened export door —
    # back shut. The day's budget is only spent by exports that produced
    # something (review 2, Opus #7).
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

    unstage!(export, blob) if discard_blob(blob, export)
  end

  def discard_blob(blob, export)
    Accounts::Purge.purge_blob_storage_first!(blob, account_id: export.account_id)
  rescue Accounts::Purge::StorageFailure => e
    ErrorReport.error(e, account_id: export.account_id, account_export_id: export.id)

    false
  end
end
