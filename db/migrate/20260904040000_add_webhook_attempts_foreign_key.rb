# frozen_string_literal: true

# The one row in the account-purge inventory that could outlive its parent
# (review 9, C3).
#
# SendWebhookRequest creates the WebhookEvent, then makes the outbound call to
# the customer's own server — up to fifteen seconds of somebody else's
# latency — and only THEN inserts the WebhookAttempt, which holds the response
# body their endpoint sent back. `webhook_event_id` had no foreign key behind
# it, so an attempt landing inside that window was inserted against an event
# the purge had already deleted: a row nothing could ever find again, holding
# customer data, under an account we had told the customer was destroyed.
#
# Accounts::Purge answers this with a census — the event ids written down
# before the walk starts — and that narrows the window but cannot close it.
# An attempt inserted after the purge's final emptiness check still succeeds,
# and the next run's census is built fresh from events that no longer exist,
# so nothing ever looks for the orphan again.
#
# A real foreign key closes it, because the DATABASE then serialises the two
# statements against each other: the insert takes a FOR KEY SHARE lock on the
# event row, so it either lands before the delete (and is swept, or refuses
# the tombstone) or after it, in which case it FAILS instead of quietly
# succeeding. `on_delete: :cascade` is the other half — deleting an event now
# takes its attempts with it, whichever door the delete came through.
#
# The orphans already in the table are deleted first: they are rows that
# belong to accounts we promised to empty, and the constraint cannot be
# created while they are there.
class AddWebhookAttemptsForeignKey < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      DELETE FROM webhook_attempts
       WHERE NOT EXISTS (SELECT 1 FROM webhook_events WHERE webhook_events.id = webhook_attempts.webhook_event_id)
    SQL

    add_foreign_key :webhook_attempts, :webhook_events, on_delete: :cascade
  end

  def down
    remove_foreign_key :webhook_attempts, :webhook_events
  end
end
