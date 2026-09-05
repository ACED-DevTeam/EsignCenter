# frozen_string_literal: true

# One account's purge, on its own, so a single account that cannot be emptied
# never stops the rest of the night's work (Accounts::Retention.purge_due!
# enqueues one of these per account).
#
# TWO STEPS, and the split is the point (review batch 2, P1).
#
#   1. Under a SHORT lock: re-check eligibility and stamp a claim
#      (`accounts.purge_started_at`, and `archived_at` with it). Commit.
#   2. Outside any transaction: run the purge.
#
# The shape this replaces held the account's row lock across the whole purge —
# storage I/O included. That was wrong twice over: a failure near the end
# rolled back the row deletes while the FILES were already gone, and every
# "Cancel deletion" queued behind minutes of file deletion.
#
# The claim is what makes the split safe, and it is a BARRIER, not a note: it
# stamps `archived_at` as well, which is the state every door in this
# application already understands as "this account is gone" — signer writes
# stop, tokens are refused, sign-in stops, and the quota chokepoint refuses.
# Nothing can start after the decision and expect to be honoured.
#
# THE CLAIM IS ALSO RELEASED, and that is R1. A claim left set for ever on an
# account that was never emptied is worse than the bug it prevents: every user
# is locked out, `Deletion.cancel!` refuses, and nothing on earth clears it.
# So:
#
#   * a REFUSAL (a live subscription that came back, a malformed testing
#     child) releases the claim — the account is not being destroyed, so it
#     must not go on looking as though it is;
#   * a STORAGE failure keeps the claim while there are retries left, because
#     the purge is half-done and the retry has to resume it;
#   * when those retries are exhausted the claim is released too and a person
#     is paged, because "half-purged and frozen for ever, silently" is not an
#     outcome anybody chose;
#   * and ANY OTHER failure ends the same way (review 7, P2). A database error
#     — a foreign key, a deadlock, a bug — is not a refusal and not a storage
#     problem, so neither release path ran: after the retries the account sat
#     claimed and archived for ever, every user locked out, `cancel!` refusing,
#     and nobody paged, because the "gave up" alert only fired for storage.
#
# `rake accounts:release_purge_claim[id]` is the manual door for the same
# thing (docs/account-deletion.md).
class AccountPurgeJob < ApplicationJob
  queue_as :default

  # ENQUEUED ONLY WHEN THE DECISION COMMITTED (review 8, A2). Every door that
  # starts a purge writes its audit row in a transaction and enqueues this in
  # the same breath — the operator console's Purge now button, and the nightly
  # retention sweep. Sidekiq is not in that transaction, so a COMMIT that
  # failed afterwards left the one irreversible action in the queue with no
  # record of who asked for it or why. Declared on the job rather than at the
  # call sites, so a third door added later inherits it.
  self.enqueue_after_transaction_commit = true

  # How many times a file that will not delete is worth retrying. Same count
  # as ApplicationJob's general policy; declared here because the ENDING is
  # different — the block below runs when the last attempt goes.
  MAX_STORAGE_ATTEMPTS = 5

  # And the same budget for everything else.
  MAX_ATTEMPTS = 5

  # DECLARED FIRST ON PURPOSE. ActiveJob keeps its rescue handlers in
  # declaration order and picks the LAST one that matches, so the narrow
  # StorageFailure handler below has to be registered after this catch-all or
  # it would never run.
  #
  # This is the ending for a failure nobody anticipated (review 7, P2): the
  # purge is part-done, the retries are spent, and the one thing that must not
  # happen is the account staying claimed. So the claim goes and a person is
  # told what threw.
  retry_on(StandardError, wait: :polynomially_longer, attempts: MAX_ATTEMPTS) do |job, error|
    account_id = job.arguments.first

    Accounts::Purge.release_claim!(Account.find_by(id: account_id))

    ErrorReport.error(error, account_id:)

    OperatorAlert.deliver(
      subject: 'Account purge failed',
      body: "Account #{account_id} could not be purged after #{job.executions} attempts " \
            "(#{error.class}: #{error.message}). The purge claim has been released so the account is " \
            'usable again, but it may be PART-EMPTIED: some documents and files may already be gone. ' \
            'Investigate the error before deciding whether to finish it ' \
            "(rake accounts:purge[#{account_id}])."
    )
  end

  # A storage failure keeps the claim while there are attempts left, because
  # the purge is half-done and the retry has to resume it. When the last one
  # goes, this runs: without it the account is still claimed, still frozen,
  # and nobody would ever look at it again.
  retry_on(Accounts::Purge::StorageFailure, wait: :polynomially_longer,
                                            attempts: MAX_STORAGE_ATTEMPTS) do |job, error|
    account_id = job.arguments.first

    Accounts::Purge.release_claim!(Account.find_by(id: account_id))

    OperatorAlert.deliver(
      subject: 'Account purge gave up',
      body: "Account #{account_id} could not be purged after #{job.executions} attempts (#{error.message}). " \
            'The purge claim has been released so the account is usable again, but it is PART-EMPTIED: ' \
            'some documents and files are already gone. Decide whether to finish it ' \
            "(rake accounts:purge[#{account_id}]) or to investigate the storage failure first."
    )
  end

  def perform(account_id)
    account = Account.find_by(id: account_id)

    return if account.nil?
    return unless claim(account)

    Accounts::Purge.call(account)
  rescue Accounts::Purge::Refused => e
    # Not being destroyed after all, so not left looking as if it were (R1).
    Accounts::Purge.release_claim!(account)

    ErrorReport.warning(e.message, account_id:)

    nil
  end

  private

  # The short lock. Returns whether this job may go on to destroy the account.
  #
  # An account that is ALREADY claimed goes ahead without re-deciding, BUT
  # only when this run is a retry of the job that made the claim (checkpoint
  # 7, C7). A resumed run must not re-decide — a half-emptied account no
  # longer looks eligible (its users may be gone), so re-deciding would refuse
  # to finish what it started and leave it half-emptied for ever. A FIRST
  # attempt that finds a claim, on the other hand, did not make it: another
  # purge is walking that family right now, or is between retries, and a
  # second walk over one family is exactly what the claim exists to stop.
  #
  # `executions` is ActiveJob's own count of attempts: 1 on the first, 2 and
  # up on every retry. A hand-driven `AccountPurgeJob.new.perform(id)` — the
  # console, and specs — never enters that accounting and reads 0, which is
  # somebody saying "finish this one" in as many words.
  def claim(account)
    account.with_lock do
      if account.purge_started_at.present?
        next true unless first_attempt?

        ErrorReport.info('account purge skipped: already claimed by another run', account_id: account.id)

        next false
      end

      unless Accounts::Retention.purge_eligible?(account, now: Time.current)
        ErrorReport.info('account purge skipped: no longer eligible', account_id: account.id)

        next false
      end

      Accounts::Purge.claim!(account)

      true
    end
  end

  def first_attempt?
    executions == 1
  end
end
