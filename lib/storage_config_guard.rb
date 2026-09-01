# frozen_string_literal: true

# Boot-time sanity check: an `active_storage` EncryptedConfig row is a leftover
# of the DB-backed storage settings that this deployment no longer reads. If
# one exists but no storage env var is set, files land on the container's
# local disk — worth an alert, never worth refusing to boot.
module StorageConfigGuard
  STORAGE_ENV_KEYS = %w[S3_ATTACHMENTS_BUCKET GCS_BUCKET AZURE_CONTAINER].freeze

  module_function

  def check!
    return unless Rails.env.production?
    return if STORAGE_ENV_KEYS.any? { |key| ENV[key].present? }
    return unless EncryptedConfig.exists?(key: EncryptedConfig::FILES_STORAGE_KEY)

    message = "active_storage config rows exist but none of #{STORAGE_ENV_KEYS.join('/')} is set; " \
              'attachments are being written to local disk'

    Rails.logger.warn(message)
    ErrorReport.warning(message)
  rescue ActiveRecord::ActiveRecordError, PG::Error
    # No database yet (assets:precompile, db:create): nothing to check.
    nil
  end
end
