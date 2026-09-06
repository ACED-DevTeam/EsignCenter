# frozen_string_literal: true

# Tell a webhook nobody has claimed apart from one whose replay BROKE.
#
# `pending_email_events` holds Postmark callbacks that arrived before the send
# row they belong to (PostmarkWebhooks). The hourly sweep replays them and
# drops whatever has waited longer than a send row can plausibly take — but
# `attribute_pending!` also catches and reports a replay that RAISES (a
# timeline write, a sending-pause write), leaving the row parked for the next
# tick. Both kinds of row then aged out at three days together, so a bounce
# that Postmark had already been told 200 about, and that we really could
# attribute, was deleted because the write kept failing (review 2, M8).
#
# `attempts` and `attribution_error` are what tell them apart: a row that has
# ever failed keeps its error, is retried by every sweep, is surfaced to the
# operator once it has failed enough times, and is never expired by the clock.
# A row that simply never matched anything still ages out at three days.
#
# Safe on existing data: both columns are added nullable/defaulted and nothing
# is rewritten. The index is the sweep's own lookup for the errored rows, and
# it is built CONCURRENTLY because this table takes a row per unattributed
# webhook and is written on the request path.
class AddAttributionErrorToPendingEmailEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    # One ALTER for the three columns, and skipped outright if they are already
    # there: this migration runs outside a transaction (the concurrent index
    # below), so a failure part-way has to be safe to run again.
    unless column_exists?(:pending_email_events, :attempts)
      change_table :pending_email_events, bulk: true do |t|
        t.integer :attempts, default: 0, null: false
        t.string :attribution_error
        t.datetime :last_attempted_at
      end
    end

    add_index :pending_email_events, :attribution_error, algorithm: :concurrently, if_not_exists: true,
                                                         where: 'attribution_error IS NOT NULL',
                                                         name: 'index_pending_email_events_on_failed_replays'
  end

  def down
    remove_index :pending_email_events, name: 'index_pending_email_events_on_failed_replays',
                                        algorithm: :concurrently, if_exists: true

    return unless column_exists?(:pending_email_events, :attempts)

    change_table :pending_email_events, bulk: true do |t|
      t.remove :last_attempted_at, :attribution_error, :attempts
    end
  end
end
