# frozen_string_literal: true

module Quotas
  # Storage is the one quota that applies to paid accounts too (10 GB per
  # seat) — and the one that never touches sending or signing. It blocks
  # ACCOUNT-USER uploads only: every path that stores a document for a
  # template goes through Templates::CreateAttachments.call, which asks
  # `assert_available!` before a single blob is created; the branding logo
  # asks the same. Signer uploads (field files, signatures), the generated
  # signed PDFs, audit trails, preview images and Word-conversion output are
  # never refused (docs/quotas-and-limits.md section 5). The refusal is
  # Quotas::StorageLimitReached (lib/quotas/storage_limit_reached.rb).
  #
  # "Used" is honest: every blob attached to anything the billing account
  # (plus its linked children) owns — templates, submissions, submitters,
  # the account logo, user signatures, and the preview images hanging off
  # those attachments — each blob counted once, in one SQL statement.
  module Storage
    WARNING_MAIL_KEY = 'quota_mail:storage_warning'

    module_function

    def bytes_used(account)
      ActiveStorage::Blob.where(id: owned_attachments(Quotas.account_ids(account)).select(:blob_id))
                         .sum(:byte_size)
    end

    # nil = unlimited (internal and operator accounts).
    def limit_bytes(account)
      Quotas.limits_for(account).storage_bytes
    end

    def assert_available!(account, incoming_bytes)
      limit = limit_bytes(account)

      return true if limit.nil?

      used = bytes_used(account)
      incoming = incoming_bytes.to_i

      return true if used + incoming <= limit

      raise StorageLimitReached.new(used:, limit:, incoming:)
    end

    # One warning email per month once the account sits at 80% of its cap.
    # The durable counter is the once-per-month guard (same pattern as the
    # completion warning).
    def after_upload(account)
      billing = Plans.billing_account(account)
      limit = limit_bytes(billing)

      return if limit.nil?
      return if bytes_used(billing) < (limit * Limits::WARNING_FRACTION).ceil
      return unless AccountCounters.increment!(billing.id, WARNING_MAIL_KEY) == 1

      QuotaMailer.storage_warning(billing).deliver_later!
    end

    # The size of what a caller is about to store, read from the uploaded
    # files themselves before any of them is opened.
    def incoming_bytes(files)
      Array.wrap(files).sum { |file| file_size(file) }
    end

    def file_size(file)
      return file.size.to_i if file.respond_to?(:size)
      return file.tempfile.size.to_i if file.respond_to?(:tempfile)

      0
    end

    def message_for(used:, limit:, locale: nil)
      I18n.with_locale(locale || I18n.locale) do
        I18n.t('storage_limit_reached', used: human_size(used), limit: human_size(limit))
      end
    end

    def human_size(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes)
    end

    # Attachments on the records the account owns, plus the preview images
    # attached to those attachments.
    def owned_attachments(ids)
      direct = direct_attachments(ids)
      previews = ActiveStorage::Attachment.where(record_type: 'ActiveStorage::Attachment',
                                                 record_id: direct.select(:id))

      direct.or(previews)
    end

    # Not listed: DynamicDocument / DynamicDocumentVersion attachments. The
    # models exist in the upstream schema, but nothing in this fork creates
    # the first row of either — no controller, service or job builds one
    # (Templates::CloneAttachments only copies ones that already exist), so
    # there is no blob to count. Add the two record types here (a
    # DynamicDocument belongs to a template; a version to its document) the
    # day a feature starts creating them.
    def direct_attachments(ids)
      attachments = ActiveStorage::Attachment

      attachments.where(record_type: 'Template', record_id: Template.where(account_id: ids).select(:id))
                 .or(attachments.where(record_type: 'Submission',
                                       record_id: Submission.where(account_id: ids).select(:id)))
                 .or(attachments.where(record_type: 'Submitter',
                                       record_id: Submitter.where(account_id: ids).select(:id)))
                 .or(attachments.where(record_type: 'Account', record_id: ids))
                 .or(attachments.where(record_type: 'User', record_id: User.where(account_id: ids).select(:id)))
    end
  end
end
