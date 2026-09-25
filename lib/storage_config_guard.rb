# frozen_string_literal: true

# Boot-time storage check. Production refuses to start when the files the
# database already points at could not be served by this boot's storage.
#
# The code before the standalone work could read storage settings from an
# `active_storage` EncryptedConfig row (the old storage settings screen). When
# no storage env var was set, it used that row and stamped every new blob
# with the row's service name (`aws_s3`, `google`, `azure` or `disk`). This
# code reads storage from the environment only, and without a bucket it falls
# back to the container disk — which Render wipes on every deploy. Booting in
# that state would look healthy while every signed PDF 404s, so it is refused
# instead:
#
#   * a legacy storage row exists and no storage env var is set — the old
#     code would have used the row, this code would use the empty disk;
#   * a blob names a service storage.yml does not define — it cannot resolve;
#   * a blob names a cloud service whose env switch is not set — it resolves
#     to a bucket-less service.
#
# Blobs on `disk` while a bucket is configured are only a warning: the old
# code already served those from the same wiped disk, so refusing the deploy
# would not bring them back. The env-only half of this (a bucket is set, or
# local disk is explicitly allowed) is ProductionReadiness.storage_backend_check.
module StorageConfigGuard
  STORAGE_ENV_KEYS = ProductionReadiness::STORAGE_ENV_KEYS

  # The env switch each cloud service in config/storage.yml needs.
  SERVICE_ENV_KEYS = {
    'aws_s3' => 'S3_ATTACHMENTS_BUCKET',
    'google' => 'GCS_BUCKET',
    'azure' => 'AZURE_CONTAINER'
  }.freeze

  class Refused < StandardError; end

  module_function

  def check!
    return unless Rails.env.production?

    problems, warnings = evaluate(**inventory)

    warnings.each do |message|
      Rails.logger.warn(message)
      ErrorReport.warning(message)
    end

    return if problems.empty?

    raise Refused, "Storage check refused to boot: #{problems.join('; ')}. " \
                   'See docs/render-deploy-checklist.md, "Storage pre-check".'
  end

  # Pure: every input is passed in, so the rules can be tested without a
  # production boot. Returns [problems, warnings]; problems refuse the boot.
  def evaluate(env:, blob_services:, defined_services:, legacy_row:)
    cloud_env = STORAGE_ENV_KEYS.any? { |key| env[key].present? }
    problems = []
    warnings = []

    if legacy_row && !cloud_env
      problems << "an active_storage settings row exists in the database but none of #{STORAGE_ENV_KEYS.join('/')} " \
                  'is set (the previous code stored files where that row pointed; set the matching env variables)'
    end

    blob_services.each do |service, count|
      if defined_services.exclude?(service)
        problems << "#{count} stored file(s) use storage service '#{service}', which config/storage.yml does not define"
      elsif SERVICE_ENV_KEYS.key?(service) && env[SERVICE_ENV_KEYS[service]].blank?
        problems << "#{count} stored file(s) use storage service '#{service}' " \
                    "but #{SERVICE_ENV_KEYS[service]} is not set"
      elsif service == 'disk' && cloud_env
        warnings << "#{count} stored file(s) use the local 'disk' service while cloud storage is configured; " \
                    'those files are only readable if the disk they were written to still exists'
      end
    end

    [problems, warnings]
  end

  # Service names and counts only; no configuration value is read. A database
  # that does not exist yet (assets:precompile, db:create) or has no blob
  # table yet (a fresh install before its migrations) has nothing to check.
  def inventory
    blob_services = self.blob_services

    { env: ENV, blob_services:, defined_services:,
      legacy_row: EncryptedConfig.exists?(key: EncryptedConfig::FILES_STORAGE_KEY) }
  rescue ActiveRecord::ActiveRecordError, PG::Error
    { env: ENV, blob_services: {}, defined_services: [], legacy_row: false }
  end

  def blob_services
    return {} unless ActiveStorage::Blob.table_exists?

    ActiveStorage::Blob.group(:service_name).count
  end

  # The service names config/storage.yml defines. Active Storage parses that
  # file when the Blob class first loads, which blob_services has done.
  def defined_services
    ActiveStorage::Blob.services

    Rails.configuration.active_storage.service_configurations.to_h.keys.map(&:to_s)
  end
end
