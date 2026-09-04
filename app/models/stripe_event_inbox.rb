# frozen_string_literal: true

# == Schema Information
#
# Table name: stripe_event_inboxes
#
#  id                :bigint           not null, primary key
#  api_version       :string
#  attempts          :integer          default(0), not null
#  event_type        :string           not null
#  last_error        :text
#  payload           :text             not null
#  processed_at      :datetime
#  status            :string           default("pending"), not null
#  stripe_created_at :datetime
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint
#  stripe_event_id   :string           not null
#
# Indexes
#
#  index_stripe_event_inboxes_on_account_id                        (account_id)
#  index_stripe_event_inboxes_on_event_type_and_stripe_created_at  (event_type,stripe_created_at)
#  index_stripe_event_inboxes_on_status                            (status)
#  index_stripe_event_inboxes_on_stripe_event_id                   (stripe_event_id) UNIQUE
#
# One row per Stripe webhook delivery, stored with the exact bytes Stripe
# signed. The endpoint's only job is to verify, insert and acknowledge; every
# decision about what an event means happens in ProcessStripeEventJob, which
# re-fetches the current object from Stripe rather than trusting the payload
# (deliveries arrive out of order; the object is the truth, the event is only
# the trigger).
class StripeEventInbox < ApplicationRecord
  PENDING = 'pending'
  PROCESSING = 'processing'
  PROCESSED = 'processed'
  IGNORED = 'ignored'
  FAILED = 'failed'

  STATUSES = [PENDING, PROCESSING, PROCESSED, IGNORED, FAILED].freeze

  # A row nothing will look at again: it either did its work or was decided
  # to be none of ours.
  TERMINAL_STATUSES = [PROCESSED, IGNORED].freeze

  # How long a row may sit `pending` — stored by the endpoint, never picked
  # up — before the reconciliation job assumes its enqueue was lost.
  STUCK_AFTER = 15.minutes

  # How long a row may sit `processing` before the reconciliation job decides
  # the worker holding it died and releases the claim (checkpoint 7, P1).
  #
  # Longer than STUCK_AFTER on purpose. A `processing` row means a worker is
  # INSIDE dispatch right now; a failure would have written `failed` and
  # handed the row back on its own, and Sidekiq's whole retry chain for this
  # job (five retries, ~17 minutes of backoff) plus its shutdown grace fits
  # inside half an hour. So a claim older than this cannot belong to a worker
  # that is still alive — and releasing one that IS alive would only spend a
  # second attempt on an event that is already being handled, which is the
  # noise the compare-and-set claim was added to stop.
  STALE_CLAIM_AFTER = 30.minutes

  # Sidekiq's retry budget for ProcessStripeEventJob; a row that has spent it
  # is not re-enqueued by reconciliation.
  MAX_ATTEMPTS = 5

  ERROR_LIMIT = 1000

  validates :stripe_event_id, presence: true, uniqueness: true
  validates :event_type, presence: true
  validates :payload, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # ApplicationRecord strips whitespace off every string attribute, which
  # would quietly eat a trailing newline off the body Stripe signed — and a
  # stored event that no longer verifies is a stored event nobody can trust.
  # This callback is declared here, so it runs AFTER the inherited one, and
  # puts the exact received bytes back.
  before_validation :restore_raw_payload

  # And the exception to storing Stripe's bytes untouched: an event about an
  # account that has already been purged (checkpoint 7, C5).
  #
  # Stripe keeps talking about a cancelled subscription for a while — a late
  # `customer.subscription.deleted`, a final `invoice.*` — and those events
  # still resolve to the tombstone's account, because the subscription row is
  # deliberately kept. They used to be stored exactly as they arrived: the
  # customer's name, address, email and a working link to a Stripe-hosted
  # invoice page, written into a database that had promised them their data
  # was gone. The purge's own scrub had already run and cannot run again, so
  # the scrub happens on the way IN.
  #
  # It has to watch `account_id`, not just `payload` (checkpoint 7, P2). The
  # webhook endpoint inserts the row with NO account: which account an event
  # is about is only worked out later, by ProcessStripeEventJob, and that is
  # the moment the row becomes attributable to a tombstone. Watching the
  # payload alone meant the scrub fired only when the stored bytes happened
  # to be rewritten on that save — which is to say, by accident.
  before_save :scrub_payload_of_purged_account,
              if: -> { will_save_change_to_payload? || will_save_change_to_account_id? }

  scope :unprocessed, -> { where.not(status: TERMINAL_STATUSES) }
  # Stored and then never picked up: the enqueue was lost. Nothing holds the
  # row, so the sweep can simply enqueue it again.
  scope :stuck, lambda { |now = Time.current|
    where(status: PENDING).where(updated_at: ...(now - STUCK_AFTER))
  }
  # Claimed and then abandoned: the worker died mid-dispatch. The claim is a
  # compare-and-set over `pending`/`failed`, so such a row has to be RELEASED
  # before it can be worked again — see StripeReconciliationJob (P1).
  scope :stale_claims, lambda { |now = Time.current|
    where(status: PROCESSING).where(updated_at: ...(now - STALE_CLAIM_AFTER))
  }
  scope :retryable, -> { where(status: FAILED).where(attempts: ...MAX_ATTEMPTS) }

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  # The verified bytes, parsed. Never re-verified here: only rows the endpoint
  # already verified exist.
  def event
    @event ||= JSON.parse(payload)
  end

  def event_object
    event.dig('data', 'object') || {}
  end

  def payload=(value)
    @raw_payload = value.is_a?(String) ? value.dup : nil
    @payload_assigned = true

    super
  end

  private

  # The bytes Stripe signed, put back after ApplicationRecord's whitespace
  # stripping has had its way with them — on EVERY save, not only the insert
  # (checkpoint 7, P2). A row loaded from the database and re-saved for some
  # other column (the job stamping `account_id`, say) was going through the
  # same stripping with nothing to restore it, so a body that ended in a
  # newline quietly lost it: the stored event no longer verified, and whether
  # the payload "changed" on that save depended on trailing whitespace.
  def restore_raw_payload
    raw = @payload_assigned ? @raw_payload : attribute_in_database(:payload)

    self[:payload] = raw if raw && self[:payload] != raw
  end

  # The same walk the purge uses, so what a late event keeps and what a purged
  # account's older events keep are decided in exactly one place.
  def scrub_payload_of_purged_account
    return if account_id.blank?
    return unless Account.where(id: account_id).where.not(purged_at: nil).exists?

    self[:payload] = Accounts::Purge.scrub_payload(self[:payload])
  end
end
