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

    # A document is still in the bucket. Deliberately NOT a Refused: a refusal
    # is a decision that will be just as true in six seconds and is never
    # retried, whereas this is a storage problem that usually clears — the job
    # retries it, and until it clears the account is not stamped as purged
    # (review batch 2, K4).
    class StorageFailure < StandardError; end

    # The two OAuth tables upstream DocuSeal left in the schema. The Doorkeeper
    # gem is NOT in this application, so there is no model to ask — but the
    # foreign keys to `users` are real and they RESTRICT, so one legacy row
    # blew the purge up half-way through, after the documents were gone and
    # before the tombstone (review batch 2, K7). Two throwaway relations, so
    # the delete is bound and quoted like every other one in this file rather
    # than being an interpolated SQL string.
    class OauthAccessGrant < ApplicationRecord
      self.table_name = 'oauth_access_grants'
    end

    class OauthAccessToken < ApplicationRecord
      self.table_name = 'oauth_access_tokens'
    end

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
      access_tokens mcp_tokens user_configs encrypted_user_configs
      oauth_access_grants oauth_access_tokens users
    ].freeze

    # What a purged account's row is renamed to. Not the customer's company
    # name: a tombstone must not still say who it was.
    TOMBSTONE_NAME = 'Deleted account'

    # Keys inside a stored Stripe event whose values are the CUSTOMER rather
    # than the transaction: who they are, where they live and how to reach
    # them. Every one of them is scrubbed out of the events we keep after a
    # purge; everything else — ids, amounts, currencies, statuses, prices,
    # timestamps — stays, because that is what makes the row an audit.
    #
    # Deliberately generous. `name` also catches a product's name and
    # `description` a line item's, neither of which is personal, but Stripe
    # puts a person's name and a free-typed description in the same shapes and
    # nothing downstream reads either: over-redacting costs an operator a
    # glance at the Stripe dashboard, under-redacting keeps a customer's
    # details after we told them they were gone.
    PERSONAL_PAYLOAD_KEYS = %w[
      address addresses billing_details business_name city collected_information custom_fields
      customer_address customer_details customer_email customer_name customer_phone customer_tax_exempt
      customer_tax_ids description email individual_name line1 line2 name owner payment_method_details
      phone postal_code receipt_email shipping shipping_address shipping_details state tax_ids
    ].freeze

    # The marker left behind. A row whose payload could not be parsed at all
    # is replaced outright rather than guessed at — `payload` is NOT NULL, and
    # bytes we cannot read are bytes we cannot promise are impersonal.
    REDACTED = '[redacted]'
    UNREADABLE_PAYLOAD = '{"redacted":true}'

    module_function

    # --- the claim ---------------------------------------------------------
    #
    # Stamped by AccountPurgeJob (and by `rake accounts:purge`) under the
    # account's row lock, a moment before anything is destroyed.
    #
    # `archived_at` goes on WITH it, and that is the whole barrier (review
    # batch 2, R2): "archived" is the state every door in this application
    # already understands as "this account is gone" — the signer write paths,
    # the token guard (AccountStates::TOKEN_REFUSAL_STATES), sign-in, and the
    # quota chokepoint all read it. Teaching each of those about a second new
    # column would have meant eight new call sites and one of them forgotten;
    # an account whose documents are being deleted is archived, so it says so.
    #
    # Testing children are claimed with their parent, because they are emptied
    # with it (R2c).
    def claim!(account)
      family(account).each do |record|
        record.update_columns(purge_started_at: record.purge_started_at || Time.current,
                              archived_at: record.archived_at || Time.current,
                              updated_at: Time.current)
      end

      true
    end

    # And released, for the two endings that are not "destroyed": a refusal,
    # and a storage failure whose retries ran out (R1). `archived_at` is put
    # back only if this claim is what set it — an account somebody archived on
    # purpose stays archived.
    def release_claim!(account)
      return false if account.nil? || account.purged?

      family(account).each do |record|
        next if record.purge_started_at.blank?

        archived = record.archived_at
        record.update_columns(purge_started_at: nil,
                              archived_at: (archived if archived && archived < record.purge_started_at),
                              updated_at: Time.current)
      end

      true
    end

    # The account and every testing child of it: one tenant, claimed and
    # released together.
    #
    # THE LINK ROWS ARE WHAT MAKE THIS ANSWER SURVIVE A FAILED RUN (review 9,
    # C1), and that is why `delete_account_rows!` no longer takes them: an
    # `account_linked_accounts` row of type `testing` is the only thing in the
    # database that says a child belongs to a parent, and the walk used to
    # delete it as soon as the CHILD had been emptied. If the parent's own
    # purge then raised — a storage failure, a deadlock — the retry rebuilt
    # this list and found only the parent. It could then entomb the parent
    # while the child sat archived, claimed, half-emptied and never stamped
    # `purged_at`, and `release_claim!` could not reach it either, so the
    # exhausted-retry release left it frozen for ever with nobody able to
    # name it. So the family's own links are kept until every member has been
    # emptied and the children have been entombed; see `delete_family_links!`.
    def family(account)
      [account, *account.testing_accounts.to_a]
    end

    # The links that tie two members of one family together — a parent and its
    # testing children. Deleted last of all, so until then any run can rebuild
    # the family from the database.
    def family_links(ids)
      AccountLinkedAccount.where(account_id: ids, linked_account_id: ids)
    end

    # And the links that reach OUTSIDE the family: a link to somebody else's
    # account, or somebody else's link to ours. Those are ordinary inventory
    # rows and the walk takes them exactly as it always did.
    def foreign_links(ids)
      AccountLinkedAccount.where(account_id: ids)
                          .or(AccountLinkedAccount.where(linked_account_id: ids))
                          .where.not(id: family_links(ids))
    end

    # The last rows of the whole purge, and deliberately after the children
    # have their tombstones. The order matters for every way this can fail:
    #
    #   * a failure BEFORE this point leaves the links in place, so the retry
    #     and the release path both still see the whole family;
    #   * a failure HERE leaves the children entombed and the parent not, and
    #     the retry re-derives the same family, walks a family that is already
    #     empty, and deletes these rows again;
    #   * a failure AFTER this point (entombing the parent) leaves a family of
    #     one, which is the truth by then — the children are already purged.
    def delete_family_links!(family)
      family_links(family.map(&:id)).delete_all

      nil
    end

    # The whole thing. Returns :purged, or :already_purged when there was
    # nothing left to do.
    def call(account)
      return :already_purged if account.nil? || account.purged?

      # Re-asserted HERE, as the first thing this method does, and not only in
      # the job that called it (review batch 2, P1). The job's claim and this
      # purge no longer share a transaction, so between them a webhook can
      # apply a Stripe subscription and put the account back on a paid plan.
      # The refusals are cheap and they are the last line: an account nobody
      # may destroy is not destroyed however it got here — the nightly sweep,
      # a resumed retry, or `rake accounts:purge` typed by hand.
      assert_purgeable!(account)

      # A testing child is not an account of its own — it is a corner of this
      # one, sharing its name and its certificates — so it goes with it. It
      # gets the SAME safety checks as the parent before anything is touched
      # (review batch 2, K2): riding in on the parent's coat-tails, a child
      # skipped every one of them, so a malformed link could have emptied an
      # internal account and a child holding its own live subscription could
      # have been destroyed while its card was still being charged. One
      # refusal stops the whole purge, parent included — a family is emptied
      # completely or not at all.
      testing_children = account.testing_accounts.to_a

      assert_children_purgeable!(testing_children, account)

      family = [account, *testing_children]
      family_ids = family.map(&:id)

      # Read BEFORE anything is destroyed, because it is what proves the walk
      # was complete (review 7, P1): afterwards there are no templates,
      # submitters or users left to ask which files hung off them.
      census = census_for(family)

      testing_children.each { |child| purge_contents!(child, census, family_ids) }
      purge_contents!(account, census, family_ids)

      # A second pass over the whole family, and then a count (review batch 2,
      # R2d). The walk above works from ids collected at its start, so
      # anything that arrived DURING it — a webhook that wrote a submitter, a
      # background job that generated a document, an attachment saved a second
      # after its record's ids were read — would survive, and the tombstone
      # would then say the account was emptied when it was not. Stragglers are
      # taken; if anything is still standing after that, the purge fails
      # rather than lying.
      family.each { |record| purge_contents!(record, census, family_ids) }

      assert_emptied!(account, family, census)

      testing_children.each { |child| entomb!(child) }

      # Only now, with every member emptied and every child stamped, is the
      # family safe to forget (C1).
      delete_family_links!(family)

      entomb!(account)

      ErrorReport.info('account purged', account_id: account.id)

      :purged
    end

    # Never destroy an account somebody is still paying for, and never destroy
    # the platform. Both raise, and both tell the operator: an account that
    # reached its purge date still holding a live subscription means the
    # cancellation never landed, and that is money still leaving a customer's
    # card.
    #
    # `Plans.live_subscription?`, NOT `Plans.paid_subscription?` (review 8,
    # A2). The paid question asks what the app currently GRANTS; this one asks
    # whether money can still move. Stripe's `unpaid` and `paused` map to a
    # local access_state of `suspended` and `incomplete` maps to `cancelled`,
    # so the paid question said "free, go ahead" over three subscriptions that
    # are still live at Stripe and revivable from the customer portal — and
    # the deletion-time cancellation is allowed to fail into a retrying job
    # (Accounts::Deletion), so "the cancellation never landed" is a state that
    # really happens. Destroying the account then is irreversible while the
    # card is not.
    def assert_purgeable!(account)
      refuse!(account, 'it is not a customer account (internal and operator accounts are the platform itself)') \
        unless account.customer?

      refuse!(account, 'it still holds a live paid subscription — cancel it at Stripe first') \
        if Plans.live_subscription?(account)

      true
    end

    # EVERY child is checked before ANY of them is touched, so a family is
    # emptied completely or not at all — half a purge is the state nobody can
    # reason about afterwards.
    def assert_children_purgeable!(children, parent)
      children.each { |child| assert_child_purgeable!(child, parent) }

      true
    end

    # Everything asked of the parent, plus the one question only a child
    # raises: is it really this parent's testing corner, and nobody else's?
    #
    # The link table is the only thing that says so, and it is ordinary data —
    # a bug or a bad backfill could point a testing link at an internal
    # account, or leave a child linked to two parents. So the child must be a
    # customer account (never the platform), must carry exactly ONE inbound
    # link, and that link must be this parent's and of type testing.
    def assert_child_purgeable!(child, parent)
      links = AccountLinkedAccount.where(linked_account_id: child.id).to_a

      unless child.customer?
        refuse!(parent, "its testing child #{child.id} is a #{child.account_kind} account, not a customer one")
      end

      unless links.one? && links.first.account_id == parent.id && links.first.testing?
        refuse!(parent, "its testing child #{child.id} is not linked to it as a testing account alone " \
                        "(#{links.size} link(s) found)")
      end

      if Plans.live_subscription?(child)
        refuse!(parent, "its testing child #{child.id} still holds a live paid subscription — " \
                        'cancel it at Stripe first')
      end

      true
    end

    def refuse!(account, why)
      message = "refusing to purge account #{account.id}: #{why}"

      OperatorAlert.deliver(subject: 'Account purge refused', body: message)

      raise Refused, message
    end

    # Every table of the inventory, for the whole family, counted for real.
    # The tombstone is only stamped when this is empty: "purged" has to mean
    # what it says, and the one thing worse than a purge that fails is a purge
    # that reports success over rows it left behind (R2d).
    def assert_emptied!(account, family, census = census_for(family))
      left = remaining_rows(family, census).reject { |_, count| count.zero? }

      return true if left.empty?

      message = "account #{account.id} is not empty after the purge: " \
                "#{left.map { |table, count| "#{table}=#{count}" }.join(', ')}"

      OperatorAlert.deliver(subject: 'Account purge did not empty the account', body: message)

      raise Refused, message
    end

    # Table name => rows still belonging to this family. Keyed on INVENTORY,
    # so a table added to that constant is counted here too or the fetch
    # raises naming it.
    def remaining_rows(family, census = census_for(family))
      ids = family.map(&:id)
      counters = row_counters(ids, census)

      INVENTORY.index_with { |table| counters.fetch(table).call }
    end

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def row_counters(ids, census = census_for(Account.where(id: ids).to_a))
      template_ids = Template.where(account_id: ids).select(:id)
      submitter_ids = Submitter.where(account_id: ids).select(:id)
      user_ids = User.where(account_id: ids).select(:id)
      document_ids = DynamicDocument.where(template_id: template_ids).select(:id)
      event_ids = WebhookEvent.where(account_id: ids).select(:id)

      { 'active_storage_attachments' => -> { census_attachment_count(census) },
        'completed_documents' => -> { CompletedDocument.where(submitter_id: submitter_ids).count },
        'document_generation_events' => -> { DocumentGenerationEvent.where(submitter_id: submitter_ids).count },
        'submitter_versions' => -> { SubmitterVersion.where(submitter_id: submitter_ids).count },
        'completed_submitters' => -> { CompletedSubmitter.where(account_id: ids).count },
        'submission_events' => -> { SubmissionEvent.where(account_id: ids).count },
        'submitters' => -> { Submitter.where(account_id: ids).count },
        'submissions' => -> { Submission.where(account_id: ids).count },
        'dynamic_document_versions' => -> { DynamicDocumentVersion.where(dynamic_document_id: document_ids).count },
        'dynamic_documents' => -> { DynamicDocument.where(template_id: template_ids).count },
        'template_sharings' => -> { TemplateSharing.where(account_id: ids).count },
        'template_accesses' => -> { TemplateAccess.where(template_id: template_ids).count },
        'template_versions' => -> { TemplateVersion.where(account_id: ids).count },
        'templates' => -> { Template.where(account_id: ids).count },
        'template_folders' => -> { TemplateFolder.where(account_id: ids).count },
        'document_metadata' => -> { DocumentMetadata.where(account_id: ids).count },
        'email_events' => -> { EmailEvent.where(account_id: ids).count },
        'email_messages' => -> { EmailMessage.where(account_id: ids).count },
        'search_entries' => -> { SearchEntry.where(account_id: ids).count },
        'webhook_attempts' => -> { census_webhook_attempt_count(census, event_ids) },
        'webhook_events' => -> { WebhookEvent.where(account_id: ids).count },
        'webhook_urls' => -> { WebhookUrl.where(account_id: ids).count },
        'abuse_flags' => -> { AbuseFlag.where(account_id: ids).count },
        'account_counters' => -> { AccountCounter.where(account_id: ids).count },
        'account_limit_overrides' => -> { AccountLimitOverride.where(account_id: ids).count },
        'account_accesses' => -> { AccountAccess.where(account_id: ids).count },
        'account_invites' => -> { AccountInvite.where(account_id: ids).count },
        # The family's OWN links are deliberately not counted here (review 9,
        # C1). They are the last rows of the purge — they outlive the walk on
        # purpose, because they are the only record of which children belong
        # to this parent and a retry has to be able to rebuild it. Everything
        # that reaches outside the family is counted exactly as before, so a
        # link this walk should have taken and did not still stops the
        # tombstone; and the end state is still empty, because
        # `delete_family_links!` runs a moment after this check passes.
        'account_linked_accounts' => -> { foreign_links(ids).count },
        'account_moves' => lambda {
          AccountMove.where(from_account_id: ids).or(AccountMove.where(to_account_id: ids)).count
        },
        'encrypted_configs' => -> { EncryptedConfig.where(account_id: ids).count },
        'account_configs' => -> { AccountConfig.where(account_id: ids).count },
        'provisioning_events' => -> { ProvisioningEvent.where(account_id: ids).count },
        'access_tokens' => -> { AccessToken.where(user_id: user_ids).count },
        'mcp_tokens' => -> { McpToken.where(user_id: user_ids).count },
        'user_configs' => -> { UserConfig.where(user_id: user_ids).count },
        'encrypted_user_configs' => -> { EncryptedUserConfig.where(user_id: user_ids).count },
        'oauth_access_grants' => -> { OauthAccessGrant.where(resource_owner_id: user_ids).count },
        'oauth_access_tokens' => -> { OauthAccessToken.where(resource_owner_id: user_ids).count },
        'users' => -> { User.where(account_id: ids).count } }
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # The completeness check must NOT ask the same question the walk asked
    # (review 7, P1). It used to: `assert_emptied!` counted attachments
    # through `attachments_for`, the walk's own query, so the check shared
    # every blind spot the walk had and could never catch one. It missed every
    # preview image in the account for exactly that reason — the walk did not
    # know about them, so neither did the count, and the tombstone was stamped
    # over customer page images still sitting in the bucket.
    #
    # So the census is taken from the RECORDS, once, before anything is
    # destroyed: the ids of every template, submission, submitter, generated
    # document, person and the account itself, plus the full set of attachment
    # ids the resolver reached (which is what a preview attachment's record_id
    # points at). Counting against those ids afterwards is independent of how
    # the walk chose to find things, so a hole in the resolver ends the purge
    # in a refusal instead of a lie.
    #
    # THE WEBHOOK EVENT IDS ARE HERE FOR THE SAME REASON (review 8, A3).
    # SendWebhookRequest inserts the attempt AFTER the outbound HTTP call has
    # finished — up to fifteen seconds after it loaded the event object. A
    # purge that deletes the event inside that window leaves the attempt
    # behind, holding the customer's webhook response body. The old count
    # asked `WebhookAttempt.where(webhook_event_id: <events of this
    # account>)`, and by then there were no events left to name, so the
    # subquery was empty and the count read zero: the account was entombed as
    # empty over a row that was still there. Captured ids cannot go blank that
    # way — the straggler is either swept by the second walk or the purge
    # refuses.
    #
    # These ids are now the BELT to a real key's braces (review 9, C3):
    # `webhook_attempts.webhook_event_id` has a foreign key with ON DELETE
    # CASCADE, so the database itself refuses an attempt whose event is gone
    # and takes the attempts with the event. The census stays because it is
    # what still catches an attempt whose event is standing — one that arrived
    # mid-walk — and because a count that depends on nothing but ids written
    # down in advance is the only kind that cannot quietly read zero.
    #
    # Both ways an event belongs to the family, matching `delete_webhooks!`:
    # by `account_id`, and through a webhook_url of the family for the old
    # rows whose account_id was never filled in.
    def census_for(family)
      ids = family.map(&:id)
      template_ids = Template.where(account_id: ids).ids
      dynamic_document_ids = DynamicDocument.where(template_id: template_ids).ids
      webhook_url_ids = WebhookUrl.where(account_id: ids).ids

      { owners: { 'Template' => template_ids,
                  'Submission' => Submission.where(account_id: ids).ids,
                  'Submitter' => Submitter.where(account_id: ids).ids,
                  'DynamicDocument' => dynamic_document_ids,
                  'DynamicDocumentVersion' =>
                    DynamicDocumentVersion.where(dynamic_document_id: dynamic_document_ids).ids,
                  'User' => User.where(account_id: ids).ids,
                  'Account' => ids },
        attachment_ids: family.flat_map { |record| family_attachment_ids(record) }.uniq,
        webhook_event_ids: (WebhookEvent.where(account_id: ids).ids +
                            WebhookEvent.where(webhook_url_id: webhook_url_ids).ids).uniq }
    end

    # Rows still hanging off anything the census named — including a preview
    # attached to an attachment we captured.
    def census_attachment_count(census)
      scope = census[:owners].map { |record_type, record_ids| owned(record_type, record_ids) }.reduce(:or)

      scope.or(owned('ActiveStorage::Attachment', census[:attachment_ids])).count
    end

    # Attempts hanging off an event the census wrote down, OR off one that
    # only appeared during the walk. The captured half is what catches the
    # attempt inserted after its event was deleted; the live half is what
    # catches an event (and its attempts) that arrived after the census was
    # taken.
    def census_webhook_attempt_count(census, event_ids)
      WebhookAttempt.where(webhook_event_id: event_ids)
                    .or(WebhookAttempt.where(webhook_event_id: census[:webhook_event_ids]))
                    .count
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

    # The census rides along because one table cannot be found from the
    # records once the walk has started: see `delete_webhooks!`. Everything
    # else is still resolved from the account, so the walk stays re-runnable
    # on its own.
    #
    # `family_ids` is the one thing this pass must NOT resolve for itself: it
    # is the family being emptied around this member, and it is what keeps the
    # walk from deleting the link rows that say the family exists (C1).
    # Defaulting to this account alone makes a lone call behave exactly as it
    # always did — there are then no intra-family links to keep.
    def purge_contents!(account, census = nil, family_ids = nil)
      purge_attachments!(account)

      delete_documents!(account)
      delete_templates!(account)
      delete_projections!(account)
      delete_webhooks!(account, census)
      delete_account_rows!(account, family_ids || [account.id])
      delete_users!(account)

      nil
    end

    # Files first, and through ActiveStorage rather than SQL: the rows below
    # are deleted with `delete_all` (no callbacks, no cascade), so anything
    # still holding a blob at that point would leave the FILE behind in the
    # bucket forever — paid-for storage of a customer's documents after they
    # asked us to destroy them.
    #
    # A blob is only destroyed when NOBODY ELSE is attached to it (review batch
    # 2, K3). The app really does share blobs across accounts:
    # Templates::CloneAttachments reuses `blob_id` rather than re-uploading,
    # and a template can be cloned into another account, so one file can be
    # two accounts' document. Taking the blob would have deleted the other
    # account's copy out from under them — their template would render a
    # missing file and there is no way back. So the shared ones lose only THIS
    # account's attachment row, and a person is told, because a shared blob is
    # also the one case where "the customer's data is gone" is not quite true.
    #
    # THE WORK IS GROUPED BY BLOB, and that is review 7's P2. Cloning a
    # template INTO YOUR OWN ACCOUNT is an ordinary feature and it reuses the
    # blob too, so two of this account's OWN attachments routinely sit on one
    # file. Nobody outside the family points at it, so it is not "shared" — but
    # attachment-at-a-time the first one deleted its object and its blob row
    # while the second attachment still pointed at that row, and the foreign
    # key threw. The rows rolled back; the FILE did not, so the surviving
    # template rendered a missing document, and every retry hit the same
    # violation for ever. One pass per blob, taking every row that names it
    # together, is an order that cannot fail that way.
    #
    # AND EVERY BLOB GOES THROUGH THE LOCKED PATH, THE SHARED ONES INCLUDED
    # (review 9, C2). A blob the snapshot called shared used to have its rows
    # taken here, with a bare `delete_all` and no lock at all — and that lost
    # customers' files outright. Two accounts really do share one blob
    # (Templates::CloneAttachments reuses `blob_id`), and if both are purged
    # at once BOTH snapshots see the other's attachment, so BOTH call the blob
    # shared and BOTH delete only their own rows. Nobody ever reaches the
    # locked path that deletes a file, so the blob row and the object survive
    # with no attachment left anywhere pointing at them: the customer's
    # document stays in the bucket for ever, unfindable, while the census —
    # which counts attachment ROWS — reports both accounts cleanly purged.
    #
    # Under the lock the question is asked again against the rows that are
    # actually left, so whichever purge goes second sees that it holds the
    # LAST reference and takes the file. The lock is per blob and is the only
    # one held, so there is no ordering between two of them to get wrong;
    # Templates::CloneAttachments, which does hold several at once, takes them
    # in id order, and the walk below hands them over in id order within each
    # layer for the same reason.
    def purge_attachments!(account)
      layers = family_attachment_layers(account)
      attachment_ids = layers.flatten

      return if attachment_ids.empty?

      # Still asked, and still asked FIRST, even though it no longer decides
      # anything: it is what tells a person which files this purge already
      # knows it will have to leave behind, BEFORE any of them is touched, and
      # that message reaches them even if the purge dies half-way through.
      # It is a snapshot, so it can be wrong in one direction — if the other
      # account's own purge releases the last reference in the meantime, the
      # locked pass below takes the file after this message said it stayed.
      # That is the conservative half of the truth and it costs an operator a
      # look in the bucket; the alternative, saying nothing until every lock
      # has been taken, costs them the whole message when the purge fails.
      shared_blob_ids = shared_blob_ids_for(attachment_ids)

      report_shared_blobs(account, shared_blob_ids)

      blob_ids_in_purge_order(layers).each do |blob_id|
        purge_blob!(account, blob_id, attachment_ids, reported: shared_blob_ids)
      end

      nil
    end

    # Every attachment this account owns, in layers: the ones hanging off its
    # own records first, then the ones hanging off THOSE, and so on.
    #
    # The second layer is real and it is not rare (review 7, P1):
    # config/initializers/active_storage.rb declares `has_many_attached
    # :preview_images` ON ActiveStorage::Attachment, so every page image of
    # every uploaded document is an attachment whose `record_type` is
    # 'ActiveStorage::Attachment'. The resolver below never named that type, so
    # the previews — rows, blob rows and the PNG files themselves — survived
    # the purge of every account that ever uploaded a document.
    #
    # DEEPEST FIRST, and that matters for the retry rather than for any foreign
    # key: a preview can only be found by walking down from its parent
    # attachment, so taking the parent first and then failing would leave the
    # previews unreachable — nothing left in the database could ever name them
    # again.
    def family_attachment_layers(account)
      layer = attachments_for(account).ids
      layers = []
      seen = []

      while layer.present?
        layers << layer
        seen.concat(layer)

        layer = ActiveStorage::Attachment.where(record_type: 'ActiveStorage::Attachment', record_id: layer)
                                         .where.not(id: seen).ids
      end

      layers
    end

    def family_attachment_ids(account)
      family_attachment_layers(account).flatten
    end

    # Every blob this account's attachments name, in the order they are worked
    # through: deepest layer first, so a preview's file goes before its parent
    # document's, and by blob id inside a layer, which is the order
    # Templates::CloneAttachments takes its locks in.
    #
    # No longer "the unshared ones" (C2): a blob that looks shared is worked
    # through here too, because whether it really is shared can only be
    # decided under its own row lock.
    def blob_ids_in_purge_order(layers)
      layers.reverse.flat_map do |ids|
        ActiveStorage::Attachment.where(id: ids).order(:blob_id).distinct.pluck(:blob_id)
      end.compact.uniq
    end

    # Every attachment this account owns: its templates' documents, its
    # submissions' audit trails and merged/preview/combined PDFs, its
    # submitters' documents, attachments and previews, the generated documents
    # hanging off its templates, the account logo, and each person's saved
    # signature and initials. The page images hanging off those attachments are
    # picked up by family_attachment_layers, which walks down from here.
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

    # Blobs of ours that some OTHER attachment also points at.
    def shared_blob_ids_for(attachment_ids)
      blob_ids = ActiveStorage::Attachment.where(id: attachment_ids).distinct.pluck(:blob_id)

      return [] if blob_ids.empty?

      ActiveStorage::Attachment.where(blob_id: blob_ids)
                               .where.not(id: attachment_ids)
                               .distinct.pluck(:blob_id)
    end

    # One blob, its file and EVERY row that names it, in the order that cannot
    # lose the file (review batch 2, K4 and P7; review 7, P2).
    #
    # ActiveStorage's own `Blob#purge` destroys the DATABASE ROWS FIRST and
    # only then deletes the object from storage. That is backwards for us: if
    # the delete fails, the rows that named the file are already gone and the
    # object is orphaned in the bucket with no locator left anywhere — a
    # customer's document, kept for ever, that nothing can ever find again to
    # remove. (The shape before this one made it worse still: it swallowed the
    # failure and stamped `purged_at`.)
    #
    # So: delete the object, delete its variants and previews, VERIFY it is
    # gone, and only then delete the rows. Any failure leaves them ALL in
    # place and raises StorageFailure — the claim stays set, `purged_at` is
    # never stamped, the job retries, and the retry still knows which file it
    # was.
    #
    # AND THE WHOLE THING HAPPENS UNDER THE BLOB'S ROW LOCK, because "is this
    # file shared?" and "delete this file" have to be ONE decision (review 8,
    # A1). `purge_attachments!` answers the share question once, at the top,
    # over the whole account; between that answer and this method a member of
    # a LINKED account can clone a template this account shared with them
    # (Abilities::TemplateConditions authorises the cross-account read, and
    # Templates::CloneAttachments reuses the blob_id rather than copying the
    # bytes). Their attachment row did not exist when the snapshot was taken,
    # so the blob still read as unshared — and the deletes below take EVERY
    # row naming the blob, deliberately. The other tenant's template lost its
    # document and the file went with it, permanently, with nothing anywhere
    # saying it had happened.
    #
    # Re-asking under `SELECT ... FOR UPDATE` closes the window from both
    # ends: a clone that has already committed is seen, and one that is still
    # in flight is BLOCKED — inserting an attachment takes a FOR KEY SHARE
    # lock on the blob row for the foreign key, and Templates::CloneAttachments
    # now takes the same lock explicitly — so it either lands before the check
    # and is honoured, or after the file is gone and the blob row with it, in
    # which case the clone's own insert fails rather than pointing at nothing.
    # The lock is held across the storage delete on purpose: a shorter one
    # would just be the same race in a smaller window.
    #
    # `reported` is the set of blobs `purge_attachments!` has already told a
    # person about, so a file that was shared before the walk started and is
    # still shared now produces ONE message rather than two.
    def purge_blob!(account, blob_id, attachment_ids, reported: [])
      # One transaction for the check, the file and all the locator rows
      # (review batch 2, R4; review 8, A1). The variant records are the
      # derivatives' own index — leaving them behind would point at files that
      # no longer exist — and deleting the blob row while an attachment
      # survived, or the other way round, would leave a half-row nobody can
      # interpret. Either they all go or none of them do, and if none do the
      # retry still finds the file by them.
      ApplicationRecord.transaction do
        blob = ActiveStorage::Blob.lock.find_by(id: blob_id)

        if blob.nil?
          ActiveStorage::Attachment.where(blob_id:).delete_all

          next
        end

        # Shared — and this is the ONE place that decision is now made, for
        # every blob, under the lock (C2). This account's rows go, with
        # `delete_all` rather than `destroy` because the destroy callback
        # would enqueue a purge of the very blob we are protecting; the file
        # and the blob row stay; and a person is told, because "everything was
        # destroyed" is then not quite true.
        if ActiveStorage::Attachment.where(blob_id:).where.not(id: attachment_ids).exists?
          ActiveStorage::Attachment.where(id: attachment_ids, blob_id:).delete_all

          report_shared_blobs(account, [blob_id]) if reported.exclude?(blob_id)

          next
        end

        delete_stored_object!(account, blob)

        # ALL of the blob's attachments, not just the ones the walk listed:
        # nobody outside the family holds this blob (that is what the check
        # above just proved, under the lock), and leaving even one row behind
        # would put the blob delete straight into a foreign-key violation (P2).
        ActiveStorage::VariantRecord.where(blob_id:).delete_all
        ActiveStorage::Attachment.where(blob_id:).delete_all
        ActiveStorage::Blob.where(id: blob_id).delete_all
      end

      nil
    end

    # The object itself, its variants and its previews. `delete_prefixed` is
    # how ActiveStorage removes a blob's derivatives, and they are as much the
    # customer's document as the original is — a preview image of a signed
    # contract left in the bucket is still their contract.
    def delete_stored_object!(account, blob)
      service = blob.service

      service.delete(blob.key)
      service.delete_prefixed("variants/#{blob.key}/")

      raise StorageFailure, "file #{blob.key} is still in storage" if service.exist?(blob.key)

      true
    rescue StandardError => e
      message = "account #{account.id}: could not delete the stored file for blob #{blob.id} (#{e.message})"

      ErrorReport.error(e, account_id: account.id, blob_id: blob.id)
      OperatorAlert.deliver(subject: 'Account purge could not delete a file', body: message)

      raise StorageFailure, message
    end

    # A shared blob is a file this account is losing that somebody else keeps.
    # It is the honest outcome — the alternative breaks the other account —
    # but it means "everything was destroyed" is not quite true for those
    # files, so it goes to a PERSON rather than only into the log (K3).
    def report_shared_blobs(account, shared_blob_ids)
      return if shared_blob_ids.empty?

      message = "purging account #{account.id} left #{shared_blob_ids.size} file(s) in place because another " \
                "account's attachment still points at them (blob ids: #{shared_blob_ids.sort.join(', ')})"

      ErrorReport.warning(message, account_id: account.id)
      OperatorAlert.deliver(subject: 'Account purge kept shared files', body: message)
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

    # An attempt used to be the only row in the inventory that could become
    # UNREACHABLE once its parent was gone: a delivery that was mid-flight
    # when the events were deleted inserted its attempt against an id nothing
    # pointed at any more, and no query starting from the account could ever
    # find it again (review 8, A3). So the second walk sweeps by the ids the
    # census wrote down BEFORE anything was destroyed, which is also what the
    # emptiness count asks against — a straggler is swept here, or the purge
    # refuses; it is never entombed in silence.
    #
    # THE DATABASE NOW ENFORCES IT TOO (review 9, C3): there is a foreign key
    # from `webhook_attempts.webhook_event_id` to `webhook_events.id` with
    # `ON DELETE CASCADE`, so an attempt cannot outlive its event at all — the
    # in-flight insert either lands before the delete or fails, and deleting
    # an event takes its attempts with it whichever line below does it.
    #
    # The three sweeps stay all the same. They are the belt to the key's
    # braces: they run in this order so nothing depends on the cascade being
    # there, they are what a mid-walk arrival is caught by on the SECOND pass
    # (the constraint stops an orphan, it does not delete a straggler whose
    # event is still standing), and the census line — now a no-op while the
    # key exists, because an attempt for a deleted event cannot be there to
    # find — is the one that would catch the orphan again if the constraint
    # were ever dropped.
    def delete_webhooks!(account, census = nil)
      event_ids = WebhookEvent.where(account_id: account.id).ids
      url_ids = WebhookUrl.where(account_id: account.id).ids

      WebhookAttempt.where(webhook_event_id: event_ids).delete_all
      WebhookAttempt.where(webhook_event_id: WebhookEvent.where(webhook_url_id: url_ids).select(:id)).delete_all
      WebhookAttempt.where(webhook_event_id: census[:webhook_event_ids]).delete_all if census
      WebhookEvent.where(account_id: account.id).delete_all
      WebhookEvent.where(webhook_url_id: url_ids).delete_all
      WebhookUrl.where(account_id: account.id).delete_all
    end

    # The account's own settings, counters and links.
    #
    # Every link EXCEPT the ones inside the family (C1): purging a child used
    # to delete the parent's own testing link, which is the only row that says
    # the child is part of this purge at all — so a parent that failed after
    # its children were emptied could never find them again, neither to finish
    # them nor to release their claim. Those rows go in `delete_family_links!`,
    # after every member is empty and the children have been entombed.
    def delete_account_rows!(account, family_ids = [account.id])
      AbuseFlag.where(account_id: account.id).delete_all
      AccountCounter.where(account_id: account.id).delete_all
      AccountLimitOverride.where(account_id: account.id).delete_all
      AccountAccess.where(account_id: account.id).delete_all
      AccountInvite.where(account_id: account.id).delete_all
      AccountLinkedAccount.where(account_id: account.id)
                          .or(AccountLinkedAccount.where(linked_account_id: account.id))
                          .where.not(id: family_links(family_ids))
                          .delete_all
      AccountMove.where(from_account_id: account.id).or(AccountMove.where(to_account_id: account.id)).delete_all
      EncryptedConfig.where(account_id: account.id).delete_all
      AccountConfig.where(account_id: account.id).delete_all
      ProvisioningEvent.where(account_id: account.id).delete_all

      # The Stripe audit is not the customer's to take away: what Stripe told
      # us and when stays, with the account it belonged to unnamed. But
      # unnaming is not de-identifying, so the payload is scrubbed FIRST.
      scrub_stripe_payloads!(account)

      StripeEventInbox.where(account_id: account.id).update_all(account_id: nil)
    end

    # Every verified webhook is stored byte for byte
    # (StripeWebhooksController), and Stripe's bytes carry the customer: their
    # email address, their name, their street address and postal code all sit
    # inside `data.object.customer_details` and `billing_details`. Clearing
    # `account_id` moved none of that — the row still said plainly who the
    # former tenant was, while docs/account-deletion.md promised their data
    # was gone (review 8, A4).
    #
    # REDACTED IN PLACE, not nulled. The column is NOT NULL, and more to the
    # point a row that is not yet terminal can still be picked up by
    # ProcessStripeEventJob (through the reconciliation sweep or Stripe's own
    # retry), which reads `event_object` for ids and statuses. So the JSON
    # keeps its shape and every id, amount, status and timestamp in it; only
    # the values under the identity keys are replaced. What is left answers
    # "what did Stripe tell us, about which object, when, and what did we do
    # with it" — the whole reason the row is kept — and names nobody.
    #
    # The stored bytes no longer match Stripe's signature afterwards. Nothing
    # re-verifies them: only rows the endpoint already verified exist at all
    # (see StripeEventInbox), and this runs once, at the end of the account's
    # life.
    def scrub_stripe_payloads!(account)
      StripeEventInbox.where(account_id: account.id).find_each do |row|
        scrubbed = begin
          scrub_personal_data(JSON.parse(row.payload)).to_json
        rescue JSON::ParserError
          UNREADABLE_PAYLOAD
        end

        # update_columns, so ApplicationRecord's whitespace stripping and the
        # model's raw-payload callback leave the scrubbed bytes exactly as
        # written.
        row.update_columns(payload: scrubbed, updated_at: Time.current)
      end

      nil
    end

    # Walks the parsed event and replaces the values under any identity key,
    # however deep. A `nil` stays `nil`: "line2": null said nothing about
    # anybody in the first place, and a redaction marker there would only make
    # the row harder to read.
    def scrub_personal_data(value)
      case value
      when Hash
        value.to_h do |key, nested|
          [key, PERSONAL_PAYLOAD_KEYS.include?(key) ? redact(nested) : scrub_personal_data(nested)]
        end
      when Array then value.map { |nested| scrub_personal_data(nested) }
      else value
      end
    end

    # Structure kept, leaves replaced — so an address stays an address-shaped
    # object with nothing in it, and any reader that walks into it finds a
    # string rather than a NoMethodError.
    def redact(value)
      case value
      when Hash then value.transform_values { |nested| redact(nested) }
      when Array then value.map { |nested| redact(nested) }
      when nil then nil
      else REDACTED
      end
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
      # Both OAuth tables restrict on `users`; see the models above (K7).
      OauthAccessGrant.where(resource_owner_id: user_ids).delete_all
      OauthAccessToken.where(resource_owner_id: user_ids).delete_all
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
    # The claim and the confirmation code go with everything else (review
    # batch 2, R7): the claim has served its purpose the moment `purged_at` is
    # stamped, and a tombstone must not still carry a credential's digest or
    # the id of the person who typed it.
    def entomb!(account)
      account.update_columns(name: TOMBSTONE_NAME,
                             archived_at: account.archived_at || Time.current,
                             purged_at: Time.current,
                             purge_started_at: nil,
                             suspended_at: nil,
                             suspension_reason: nil,
                             deletion_requested_by_id: nil,
                             deletion_code_digest: nil,
                             deletion_code_expires_at: nil,
                             deletion_code_attempts: 0,
                             deletion_code_user_id: nil,
                             deletion_code_window_started_at: nil,
                             updated_at: Time.current)
    end
  end
end
