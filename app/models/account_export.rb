# frozen_string_literal: true

# One request for "everything in this account, as a zip" (Session 8 phase D).
#
# The row IS the state: pending while it waits for a worker, running while the
# zip is being written, ready once the file is attached, failed when it could
# not be built, expired once the seven days are up and the file has been
# purged. The page reads it, the job writes it, and the two limits that keep
# this from being a way to hammer the storage bucket — one export at a time,
# five a day — are decided from it.
# == Schema Information
#
# Table name: account_exports
#
#  id              :bigint           not null, primary key
#  error           :text
#  expires_at      :datetime
#  finished_at     :datetime
#  started_at      :datetime
#  status          :string           default("pending"), not null
#  summary         :jsonb            not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  requested_by_id :bigint
#
# Indexes
#
#  index_account_exports_on_account_id                 (account_id)
#  index_account_exports_on_account_id_and_created_at  (account_id,created_at)
#  index_account_exports_on_requested_by_id            (requested_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (requested_by_id => users.id) ON DELETE => nullify
#
class AccountExport < ApplicationRecord
  PENDING = 'pending'
  RUNNING = 'running'
  READY = 'ready'
  FAILED = 'failed'
  EXPIRED = 'expired'

  STATUSES = [PENDING, RUNNING, READY, FAILED, EXPIRED].freeze

  # Not finished yet: the two states that mean a worker owns this row.
  IN_PROGRESS = [PENDING, RUNNING].freeze

  # The locator is committed before upload starts. A failed or interrupted
  # upload remains discoverable by worker cleanup, retention and account purge.
  STAGED_BLOB_ID = 'staged_blob_id'

  belongs_to :account
  # Optional, and the foreign key nullifies: the person who asked can lose
  # their seat or be deleted long before the file expires, and the export is
  # still the account's.
  belongs_to :requested_by, class_name: 'User', optional: true

  has_one_attached :archive

  validates :status, inclusion: { in: STATUSES }

  scope :newest_first, -> { order(id: :desc) }
  scope :in_progress, -> { where(status: IN_PROGRESS) }

  def in_progress?
    status.in?(IN_PROGRESS)
  end

  def ready?
    status == READY
  end

  def failed?
    status == FAILED
  end

  def expired?(now = Time.current)
    status == EXPIRED || (expires_at.present? && expires_at <= now)
  end

  # Ready AND still inside its seven days AND the file is really attached.
  # Every door that hands the zip over asks this one question.
  def downloadable?(now = Time.current)
    ready? && !expired?(now) && archive.attached?
  end

  # The build product of an attempt that has not attached anything yet, or nil
  # — which is the normal state of every row that is not being uploaded to at
  # this instant.
  def staged_blob
    blob_id = summary[STAGED_BLOB_ID]

    blob_id.present? ? ActiveStorage::Blob.find_by(id: blob_id) : nil
  end

  def stage_blob!(blob)
    update_columns(summary: summary.merge(STAGED_BLOB_ID => blob.id), updated_at: Time.current)
  end

  # Called once whatever the row named has been dealt with — attached, or
  # deleted. `update_columns` on purpose: this is bookkeeping about a file, not
  # a change of state, and it must not touch `status` or fire validations on a
  # row another process may be finishing with.
  def unstage_blob!
    return false if summary[STAGED_BLOB_ID].blank?

    update_columns(summary: summary.except(STAGED_BLOB_ID), updated_at: Time.current)
  end

  def total_bytes
    summary['total_bytes'].to_i
  end

  def counts
    summary['counts'].presence || {}
  end
end
