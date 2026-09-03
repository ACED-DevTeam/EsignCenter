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

  # How long a row may sit claimed before the reconciliation job assumes the
  # worker that claimed it died.
  STUCK_AFTER = 15.minutes

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

  scope :unprocessed, -> { where.not(status: TERMINAL_STATUSES) }
  scope :stuck, lambda { |now = Time.current|
    where(status: [PENDING, PROCESSING]).where(updated_at: ...(now - STUCK_AFTER))
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

    super
  end

  private

  def restore_raw_payload
    self[:payload] = @raw_payload if @raw_payload && self[:payload] != @raw_payload
  end
end
