# frozen_string_literal: true

module Accounts
  # The door to an account export (Session 8 phase D): who may ask for one,
  # how often, and what "ask" means when there is already one in flight.
  #
  # Three rules, and all three exist so that pressing a button repeatedly can
  # never turn into a queue of gigabyte zips:
  #
  #   * ONE AT A TIME. An export that is pending or running IS the answer to
  #     the next request — the caller gets that row back, not a second build.
  #   * A FRESH ONE IS REUSED. A ready export younger than an hour is handed
  #     back as it is; an account's data has not meaningfully changed in that
  #     time and the file is already sitting there.
  #   * FIVE A DAY. A durable per-UTC-day counter (AccountCounters), the same
  #     mechanism every other limit in the application uses, so a restart or a
  #     second web process cannot lose the count.
  #
  # The decision is made under the ACCOUNT'S ROW LOCK, so two requests that
  # arrive in the same instant cannot both find "nothing in flight" and both
  # start a build.
  module Exports
    # How long a finished export can be downloaded for.
    TTL = 7.days

    # A ready export younger than this is handed back instead of rebuilt.
    REUSE_WINDOW = 1.hour

    # Exports per account per UTC day.
    MAX_PER_DAY = 5

    COUNTER_KEY = 'account_exports'

    # A failed export's attachment (there normally is none) is not worth
    # keeping; the row stays as the record that it failed.
    FAILED_RETENTION = 1.day

    # An export whose worker died leaves the row "running" for ever, and that
    # would block every future request on the account. Anything in flight for
    # longer than this is failed by the nightly sweep so the door opens again.
    # Comfortably longer than AccountExportJob::HARD_TIMEOUT.
    STALE_AFTER = 2.hours

    # And a much shorter fuse for a row that never even STARTED (review 2,
    # Opus #7). A `pending` row that no worker has claimed did not die
    # half-way through a build — the enqueue never landed, or Redis was down —
    # so there is nothing to protect and no reason to make the customer wait
    # two hours before they may ask again.
    PENDING_STALE_AFTER = 15.minutes

    # How long the link the download button mints is good for (review 2, H5).
    # Short on purpose: it is a bearer URL that the blob proxy honours without
    # asking who is holding it, so it must not outlive the click that made it.
    # The seven days are the life of the FILE; this is the life of one link.
    DOWNLOAD_URL_TTL = 10.minutes

    # Five today already. Carries the count so the page can say it.
    class LimitReached < StandardError
      attr_reader :limit

      def initialize(limit = MAX_PER_DAY)
        @limit = limit

        super("this account has already requested #{limit} exports today")
      end
    end

    # The row was written and the job could not be handed to a worker. The
    # customer is told plainly rather than left watching a spinner for a build
    # that will never start (review 2, M8).
    class EnqueueFailed < StandardError; end

    module_function

    # The latest export of this account, whatever state it is in.
    def latest(account)
      AccountExport.where(account_id: account.id).newest_first.first
    end

    # Ask for one. Returns the AccountExport the caller should be shown —
    # which may be one that already existed. Raises LimitReached when today's
    # budget is spent.
    def request!(account, requested_by: nil, now: Time.current)
      created = nil

      account.with_lock do
        existing = reusable(account, now:)

        next if existing

        raise LimitReached if used_today(account, now:) >= MAX_PER_DAY

        created = AccountExport.create!(account:, requested_by:, status: AccountExport::PENDING)

        AccountCounters.increment!(account.id, COUNTER_KEY, period: AccountCounters.day_period(now))
      end

      return latest(account) if created.nil?

      # Enqueued AFTER the lock is released, because a worker that picks the
      # job up instantly must not queue behind the transaction that created
      # its row — and therefore the enqueue can fail on its own, with the row
      # already committed (review 2, M8). A pending row nobody is building is
      # the worst of both worlds: `reusable` hands it to every later request,
      # so one Redis wobble used to close the export door until the sweep
      # noticed. So the failure is written onto the row, the day's budget is
      # given back, and the caller is told.
      begin
        AccountExportJob.perform_async(created.id)
      rescue StandardError => e
        abandon!(created, e)

        raise EnqueueFailed, "the export could not be queued (#{e.class}: #{e.message})"
      end

      created
    end

    # A row that will never be built: marked failed so the page says so, and
    # the day's budget handed back with it.
    def abandon!(export, error)
      export.update_columns(status: AccountExport::FAILED, finished_at: Time.current,
                            error: "#{error.class}: #{error.message}".first(AccountExportJob::MAX_ERROR),
                            updated_at: Time.current)

      refund!(export)

      nil
    rescue StandardError => e
      ErrorReport.error(e, account_id: export.account_id, account_export_id: export.id)

      nil
    end

    # The daily budget is spent when the request is made, because that is the
    # only moment two requests can be serialised against each other. An export
    # that never produced a file gives it back (review 2, Opus #7): five
    # failures must not lock a customer out of their own data for the rest of
    # the day, on the one page whose whole promise is that it always works.
    #
    # Refunded against the day the export was ASKED for, not today — a build
    # that fails at ten past midnight belongs to yesterday's budget. Floored
    # at zero in SQL, so a double refund can never hand out a sixth export.
    def refund!(export)
      AccountCounter.where(account_id: export.account_id, key: COUNTER_KEY,
                           period: AccountCounters.day_period(export.created_at))
                    .where('value > 0')
                    .update_all('value = value - 1, updated_at = CURRENT_TIMESTAMP')

      nil
    end

    # The export a new request should be given instead of a new build: one
    # that is still being made, or a ready one that is younger than an hour.
    def reusable(account, now: Time.current)
      export = latest(account)

      return nil if export.nil?
      return export if export.in_progress?
      return export if export.downloadable?(now) && export.created_at > now - REUSE_WINDOW

      nil
    end

    def used_today(account, now: Time.current)
      AccountCounters.value(account.id, COUNTER_KEY, period: AccountCounters.day_period(now))
    end

    def remaining_today(account, now: Time.current)
      [MAX_PER_DAY - used_today(account, now:), 0].max
    end
  end
end
