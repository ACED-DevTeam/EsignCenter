# frozen_string_literal: true

# A Postmark webhook that arrived BEFORE the send row it belongs to (Session
# 10, review 8 D8).
#
# The endpoint used to answer such a delivery 200 and throw it away, so a
# bounce that overtook its own send row was lost for ever — and the send row
# is written by an observer that runs after the message has been handed to
# Postmark, so overtaking is a real ordering, not a theoretical one.
#
# The webhook is therefore PARKED here, keyed by the provider's message uuid
# (the `message-uuid` metadata our own mailer stamps on every message), and
# replayed the moment the matching send row is written. Two other things keep
# it honest: the endpoint re-checks for the send row immediately after
# parking, so a row that landed in between is not missed, and the hourly
# housekeeping sweep replays anything left and drops what has waited longer
# than a send row can plausibly take.
#
# `provider_event_key` carries the same uniqueness the events table uses, so
# a Postmark retry of an unattributed delivery parks one row rather than one
# per attempt.
class CreatePendingEmailEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_email_events do |t|
      t.string :provider_message_id, null: false
      t.string :provider_event_key, null: false
      t.jsonb :record, null: false, default: {}

      t.timestamps
    end

    add_index :pending_email_events, :provider_message_id
    add_index :pending_email_events, :provider_event_key, unique: true
    add_index :pending_email_events, :created_at
  end
end
