# frozen_string_literal: true

# == Schema Information
#
# Table name: pending_email_events
#
#  id                  :bigint           not null, primary key
#  attempts            :integer          default(0), not null
#  attribution_error   :string
#  last_attempted_at   :datetime
#  provider_event_key  :string           not null
#  record              :jsonb            not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  provider_message_id :string           not null
#
# Indexes
#
#  index_pending_email_events_on_created_at           (created_at)
#  index_pending_email_events_on_failed_replays       (attribution_error) WHERE (attribution_error IS NOT NULL)
#  index_pending_email_events_on_provider_event_key   (provider_event_key) UNIQUE
#  index_pending_email_events_on_provider_message_id  (provider_message_id)
#

# A Postmark webhook we could not attribute YET: the send row it belongs to
# had not been written when it arrived (Session 10, review 8 D8).
#
# It is a parking space, never a destination. Every row here is either
# replayed into `email_events` — by the observer the moment the send row is
# written, or by the hourly housekeeping sweep — or dropped by that same sweep
# once it has waited longer than a send row can plausibly take (MAX_WAIT). The
# rows carry no account: an unattributed webhook is, by definition, one we
# cannot yet say whose it is, which is also why the purge does not walk them.
# Nearly all of them are gone within the second; the ones that are not wait up
# to MAX_WAIT — three days — before the sweep drops them.
#
# EXCEPT the ones whose replay FAILED. `attribution_error` marks a row that
# really did find its send row and then broke on the way into `email_events`.
# Postmark has already been answered 200 for it, so dropping it loses a real
# bounce or complaint: those rows are kept however long they take, retried by
# every sweep, and reported to the operator once they have failed
# PostmarkWebhooks::MAX_REPLAY_ATTEMPTS times (review 2, M8).
class PendingEmailEvent < ApplicationRecord
  # How long a webhook waits for its send row before we accept it will never
  # come. Generous on purpose: the alternative to waiting is losing the event.
  MAX_WAIT = 3.days

  scope :for_message, ->(message_id) { where(provider_message_id: message_id).order(:id) }
  scope :failed, -> { where.not(attribution_error: nil) }
  # Only rows that never matched anything age out. A failed replay is a row we
  # CAN attribute and have not managed to yet, which is a bug to fix, not an
  # event to delete.
  scope :expired, ->(now = Time.current) { where(created_at: ...(now - MAX_WAIT), attribution_error: nil) }
end
