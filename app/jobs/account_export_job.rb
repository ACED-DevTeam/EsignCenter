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
# `running`, and the nightly sweep fails it after Accounts::Exports::STALE_AFTER
# so the account's door is not blocked for ever.
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
  def claim(export_id)
    export = AccountExport.find_by(id: export_id)

    return nil if export.nil? || !export.in_progress?

    export.update!(status: AccountExport::RUNNING, started_at: export.started_at || Time.current)

    export
  end

  def build!(export)
    summary = nil

    Tempfile.create(['account-export', '.zip'], binmode: true) do |file|
      summary = Accounts::ExportArchive.call(export, file.path)

      file.rewind
      export.archive.attach(io: file, filename: filename_for(export),
                            content_type: 'application/zip')
    end

    export.update!(status: AccountExport::READY, finished_at: Time.current,
                   expires_at: Accounts::Exports::TTL.from_now, error: nil, summary:)

    AccountMailer.export_ready(export).deliver_later!

    nil
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

    export.archive.purge if export.archive.attached?
    export.update!(status: AccountExport::FAILED, finished_at: Time.current, error: message)

    ErrorReport.error(error, account_id: export.account_id, account_export_id: export.id)

    AccountMailer.export_failed(export).deliver_later!

    nil
  rescue StandardError => e
    # The failure path must never be what takes the job down.
    ErrorReport.error(e, account_export_id: export&.id)

    nil
  end
end
