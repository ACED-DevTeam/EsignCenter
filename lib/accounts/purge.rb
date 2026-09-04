# frozen_string_literal: true

module Accounts
  # Permanently destroying one account's data (D43).
  #
  # This does NOT lean on `account.destroy` and its cascade of `dependent:`
  # options. A cascade is invisible: a table added next year with a foreign
  # key and no association either blows the delete up (the Session 1
  # provisioning_events bug) or, worse, quietly stays behind. So the purge
  # walks an EXPLICIT inventory, written down here and in
  # docs/account-deletion.md, and `orphans` afterwards proves the walk was
  # complete.
  #
  # Three things deliberately survive a purge:
  #
  #   * verified_documents — the /verify fingerprint records. They hold a
  #     SHA-256, a date and a signer count and name nobody, so they are not
  #     personal data; and they must outlive the account or every document it
  #     ever signed would stop verifying. Untouched, account_id included.
  #   * account_subscriptions — the money history. Stripe ids and states, no
  #     documents and no people.
  #   * the accounts row itself — renamed "Deleted account" and stamped
  #     `purged_at`, so every id that still points at it (a verified document,
  #     a Stripe inbox row) points at something rather than nowhere.
  #
  # Running it twice is a no-op: the second call sees `purged_at` and answers
  # :already_purged.
  module Purge
    # The account was never emptied. Named, because the two reasons are
    # different problems and both need a person.
    class Refused < StandardError; end

    # Tables the purge empties for an account, in dependency order — children
    # before parents. Kept as a list so the docs, the rake task and the golden
    # spec can all read the same one.
    INVENTORY = %w[
      active_storage_attachments
      completed_documents document_generation_events submitter_versions
      completed_submitters submission_events submitters submissions
      dynamic_document_versions dynamic_documents
      template_sharings template_accesses template_versions templates template_folders
      document_metadata email_events email_messages search_entries
      webhook_attempts webhook_events webhook_urls
      abuse_flags account_counters account_limit_overrides account_accesses account_invites
      account_linked_accounts account_moves encrypted_configs account_configs provisioning_events
      access_tokens mcp_tokens user_configs encrypted_user_configs users
    ].freeze

    # What a purged account's row is renamed to. Not the customer's company
    # name: a tombstone must not still say who it was.
    TOMBSTONE_NAME = 'Deleted account'

    module_function

    # The whole thing. Returns :purged, or :already_purged when there was
    # nothing left to do.
    def call(account)
      return :already_purged if account.nil? || account.purged?

      assert_purgeable!(account)

      # A testing child is not an account of its own — it is a corner of this
      # one, sharing its name and its certificates — so it goes with it, row
      # and all. Its contents are emptied by the same walk.
      testing_children = account.testing_accounts.to_a

      testing_children.each { |child| purge_contents!(child) }
      purge_contents!(account)

      testing_children.each { |child| Account.where(id: child.id).delete_all }

      entomb!(account)

      ErrorReport.info('account purged', account_id: account.id)

      :purged
    end

    # Never destroy an account somebody is still paying for, and never destroy
    # the platform. Both raise, and both tell the operator: an account that
    # reached its purge date still holding a live subscription means the
    # cancellation never landed, and that is money still leaving a customer's
    # card.
    def assert_purgeable!(account)
      refuse!(account, 'it is not a customer account (internal and operator accounts are the platform itself)') \
        unless account.customer?

      refuse!(account, 'it still holds a live paid subscription — cancel it at Stripe first') if paid_access?(account)

      true
    end

    def paid_access?(account)
      Plans::PAID_ACCESS_STATES.include?(account.account_subscription&.access_state)
    end

    def refuse!(account, why)
      message = "refusing to purge account #{account.id}: #{why}"

      OperatorAlert.deliver(subject: 'Account purge refused', body: message)

      raise Refused, message
    end

    # Rows that would be left pointing at a purged account if the walk above
    # ever missed one. Four projections chosen because they are the ones with
    # no foreign key to `accounts` — nothing in the database would complain,
    # so a spec and the rake task ask instead.
    def orphans(account_id)
      { completed_submitters: CompletedSubmitter.where(account_id:).count,
        webhook_events: WebhookEvent.where(account_id:).count,
        search_entries: SearchEntry.where(account_id:).count,
        submitters: Submitter.where(account_id:).count }
    end

    # --- the walk --------------------------------------------------------------

    def purge_contents!(account)
      purge_attachments!(account)

      delete_documents!(account)
      delete_templates!(account)
      delete_projections!(account)
      delete_webhooks!(account)
      delete_account_rows!(account)
      delete_users!(account)

      nil
    end

    # Files first, and through ActiveStorage rather than SQL: the rows below
    # are deleted with `delete_all` (no callbacks, no cascade), so anything
    # still holding a blob at that point would leave the FILE behind in the
    # bucket forever — paid-for storage of a customer's documents after they
    # asked us to destroy them.
    #
    # Blob ids are collected FIRST because purging an attachment takes its
    # blob with it, and a blob shared with another account's attachment would
    # therefore be pulled out from under them. Nothing in the app deduplicates
    # blobs across accounts, so the shared count is expected to be zero; it is
    # counted and reported rather than assumed, because being wrong about this
    # would silently break somebody else's documents.
    def purge_attachments!(account)
      attachments = attachments_for(account)
      blob_ids = attachments.pluck(:blob_id).uniq

      report_shared_blobs(account, attachments.ids, blob_ids)

      attachments.find_each(batch_size: 200) do |attachment|
        attachment.purge
      rescue StandardError => e
        # One unreadable file must not leave the rest of the account's
        # documents in the bucket. The row goes either way.
        ErrorReport.error(e, account_id: account.id, attachment_id: attachment.id)

        ActiveStorage::Attachment.where(id: attachment.id).delete_all
      end

      nil
    end

    # Every attachment this account owns: its templates' documents, its
    # submissions' audit trails and merged/preview/combined PDFs, its
    # submitters' documents, attachments and previews, the generated documents
    # hanging off its templates, the account logo, and each person's saved
    # signature and initials.
    def attachments_for(account)
      template_ids = Template.where(account_id: account.id).ids
      dynamic_document_ids = DynamicDocument.where(template_id: template_ids).ids

      ActiveStorage::Attachment.where(record_type: 'Template', record_id: template_ids)
                               .or(owned('Submission', Submission.where(account_id: account.id).ids))
                               .or(owned('Submitter', Submitter.where(account_id: account.id).ids))
                               .or(owned('DynamicDocument', dynamic_document_ids))
                               .or(owned('DynamicDocumentVersion',
                                         DynamicDocumentVersion.where(dynamic_document_id: dynamic_document_ids).ids))
                               .or(owned('User', User.where(account_id: account.id).ids))
                               .or(owned('Account', [account.id]))
    end

    def owned(record_type, ids)
      ActiveStorage::Attachment.where(record_type:, record_id: ids)
    end

    def report_shared_blobs(account, attachment_ids, blob_ids)
      return if blob_ids.empty?

      shared = ActiveStorage::Attachment.where(blob_id: blob_ids).where.not(id: attachment_ids).count

      return if shared.zero?

      ErrorReport.warning("purging account #{account.id} would take #{shared} blob(s) still attached elsewhere",
                          account_id: account.id)
    end

    # Documents, and everything projected off them.
    def delete_documents!(account)
      submitter_ids = Submitter.where(account_id: account.id).ids

      CompletedDocument.where(submitter_id: submitter_ids).delete_all
      DocumentGenerationEvent.where(submitter_id: submitter_ids).delete_all
      SubmitterVersion.where(submitter_id: submitter_ids).delete_all
      CompletedSubmitter.where(account_id: account.id).delete_all
      # Three passes, because the column that ties an event to this account
      # is nullable and old rows filled only one of the other two.
      SubmissionEvent.where(account_id: account.id).delete_all
      SubmissionEvent.where(submitter_id: submitter_ids).delete_all
      SubmissionEvent.where(submission_id: Submission.where(account_id: account.id).select(:id)).delete_all
      Submitter.where(account_id: account.id).delete_all
      Submission.where(account_id: account.id).delete_all
    end

    # Templates and their folders. Folders come last of the three because a
    # template points at one.
    def delete_templates!(account)
      template_ids = Template.where(account_id: account.id).ids
      dynamic_document_ids = DynamicDocument.where(template_id: template_ids).ids

      DynamicDocumentVersion.where(dynamic_document_id: dynamic_document_ids).delete_all
      DynamicDocument.where(id: dynamic_document_ids).delete_all
      TemplateSharing.where(template_id: template_ids).delete_all
      TemplateSharing.where(account_id: account.id).delete_all
      TemplateAccess.where(template_id: template_ids).delete_all
      TemplateVersion.where(account_id: account.id).delete_all
      TemplateVersion.where(template_id: template_ids).delete_all
      Template.where(account_id: account.id).delete_all
      # Folders nest, so children before parents: deleting in id order would
      # trip the self-referencing foreign key.
      TemplateFolder.where(account_id: account.id).order(id: :desc).each do |folder|
        TemplateFolder.where(parent_folder_id: folder.id).update_all(parent_folder_id: nil)
      end
      TemplateFolder.where(account_id: account.id).delete_all
    end

    # Search, metadata and mail projections. All rebuildable, none of them the
    # record of anything.
    def delete_projections!(account)
      DocumentMetadata.where(account_id: account.id).delete_all
      EmailEvent.where(account_id: account.id).delete_all
      EmailMessage.where(account_id: account.id).delete_all
      SearchEntry.where(account_id: account.id).delete_all
    end

    def delete_webhooks!(account)
      event_ids = WebhookEvent.where(account_id: account.id).ids
      url_ids = WebhookUrl.where(account_id: account.id).ids

      WebhookAttempt.where(webhook_event_id: event_ids).delete_all
      WebhookAttempt.where(webhook_event_id: WebhookEvent.where(webhook_url_id: url_ids).select(:id)).delete_all
      WebhookEvent.where(account_id: account.id).delete_all
      WebhookEvent.where(webhook_url_id: url_ids).delete_all
      WebhookUrl.where(account_id: account.id).delete_all
    end

    # The account's own settings, counters and links.
    def delete_account_rows!(account)
      AbuseFlag.where(account_id: account.id).delete_all
      AccountCounter.where(account_id: account.id).delete_all
      AccountLimitOverride.where(account_id: account.id).delete_all
      AccountAccess.where(account_id: account.id).delete_all
      AccountInvite.where(account_id: account.id).delete_all
      AccountLinkedAccount.where(account_id: account.id).or(
        AccountLinkedAccount.where(linked_account_id: account.id)
      ).delete_all
      AccountMove.where(from_account_id: account.id).or(AccountMove.where(to_account_id: account.id)).delete_all
      EncryptedConfig.where(account_id: account.id).delete_all
      AccountConfig.where(account_id: account.id).delete_all
      ProvisioningEvent.where(account_id: account.id).delete_all

      # The Stripe audit is not the customer's to take away: what Stripe told
      # us and when stays, with the account it belonged to unnamed.
      StripeEventInbox.where(account_id: account.id).update_all(account_id: nil)
    end

    # People last, because half the tables above point at them. Deleting the
    # row is what RELEASES the email address: Devise's unique index is the
    # only thing reserving it, so until this runs the address cannot be used
    # to sign up again — which is exactly the promise the 90-day window makes.
    def delete_users!(account)
      user_ids = User.where(account_id: account.id).ids

      return if user_ids.empty?

      AccessToken.where(user_id: user_ids).delete_all
      McpToken.where(user_id: user_ids).delete_all
      UserConfig.where(user_id: user_ids).delete_all
      EncryptedUserConfig.where(user_id: user_ids).delete_all
      TemplateAccess.where(user_id: user_ids).delete_all
      AccountMove.where(user_id: user_ids).delete_all
      AccountInvite.where(invited_by_id: user_ids).update_all(invited_by_id: nil)
      AccountInvite.where(collision_user_id: user_ids).update_all(collision_user_id: nil)
      Account.where(deletion_requested_by_id: user_ids).update_all(deletion_requested_by_id: nil)

      User.where(id: user_ids).delete_all
    end

    # What is left: a row with an id, a uuid and a date. The locale and
    # timezone stay because a tombstone still has to render in some language
    # if anything ever loads it, and neither says anything about the customer.
    def entomb!(account)
      account.update_columns(name: TOMBSTONE_NAME,
                             archived_at: account.archived_at || Time.current,
                             purged_at: Time.current,
                             suspended_at: nil,
                             suspension_reason: nil,
                             deletion_requested_by_id: nil,
                             updated_at: Time.current)
    end
  end
end
