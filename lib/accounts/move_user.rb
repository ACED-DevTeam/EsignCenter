# frozen_string_literal: true

module Accounts
  # "Join this team" (D50).
  #
  # Somebody who already had an EsignCenter account of their own accepts an
  # invitation to a team. Rather than telling them their address is taken —
  # which is what the app used to do, and which leaves them stuck — they and
  # everything they own move into the team: templates, folders, documents,
  # the lot. Their old account is archived, never deleted, because its
  # metering history and the /verify record of every document it signed are
  # still true.
  #
  # This is deliberately narrow. It runs only for a person who is ALONE in
  # their own customer account with no live subscription — one person, one
  # account, one move, in one transaction. Anything else is a refusal with an
  # explanation, never a validation error.
  #
  # The last-admin rule is kept by construction rather than by a check: the
  # move is refused unless the old account has no other active user, and the
  # emptied account is archived in the same transaction — so no account is
  # ever left running without an administrator.
  module MoveUser
    # A refusal the invitee can read and act on. Never a bug: every one of
    # these is a legitimate state somebody can be in.
    class Refused < StandardError; end

    # Every account-scoped table whose rows belong to the WORK the person is
    # bringing with them. Ordered so a row never points at a folder that has
    # not been dealt with yet.
    #
    # Deliberately NOT moved:
    #   * completed_submitters — metering is prospective (D43): what the old
    #     account used stays counted against the old account.
    #   * verified_documents — the public /verify record of a signature that
    #     was made by that account, at that time. It is history, and history
    #     does not move house.
    #   * webhook_urls, encrypted_configs, account_configs, abuse_flags,
    #     counters, limit overrides, the subscription — configuration and
    #     policy belong to the account, not to the person.
    MOVED_TABLES = [Template, TemplateSharing, TemplateVersion, Submission, Submitter, SubmissionEvent,
                    DocumentMetadata, EmailMessage, SearchEntry].freeze

    module_function

    def call(user:, to:, role: nil)
      from = user.account

      assert_movable!(user:, from:, to:)

      ApplicationRecord.transaction do
        merge_folders!(from, to)
        drop_duplicate_document_metadata!(from, to)
        MOVED_TABLES.each { |model| model.where(account_id: from.id).update_all(account_id: to.id) }

        # The seat they take in the team is a full one: whatever their old
        # account thought of them, they are a member here now.
        user.update!(account: to, role: role.presence || user.role, read_only_at: nil)

        revoke_credentials!(user)

        from.update!(archived_at: Time.current) if from.archived_at.blank?

        AccountMove.create!(from_account: from, to_account: to, user:)
      end

      user
    end

    # A move is a SECURITY-BOUNDARY transition, so every key cut for the old
    # account is thrown away as part of it.
    #
    # The move re-parents the person in place, and API and MCP auth derive the
    # tenant from the person: a token resolves its user and reads
    # `user.account` (Api::ApiBaseController#user_from_token). So every
    # credential minted while they were alone in their own one-person account
    # — the API token pasted into a script years ago, an MCP token on an old
    # laptop, a Doorkeeper grant left behind by upstream DocuSeal, the
    # remember-me cookie on a shared browser — would silently start resolving
    # to the TEAM, at whatever role the invitation granted. The team's
    # administrators never issued any of them, cannot see them and could not
    # revoke them. A leaked personal-account key is a small thing; the same
    # key against somebody else's tenant is not.
    #
    # Both token associations are cleared: `access_token` is a has_one that
    # builds itself on first read, and `access_tokens` is the has_many behind
    # it, so a row can hang off either. The cached associations are reset
    # afterwards because the user object outlives this call — the accepting
    # request goes on to use it — and a stale has_one would hand back a row
    # that no longer exists in the database.
    #
    # The two OAuth tables have no model in this application (the Doorkeeper
    # gem is not installed); Accounts::Purge already owns the two throwaway
    # relations for them, and they are reused here rather than defined a
    # second time, so there is one place that knows those tables exist.
    #
    # What this canNOT revoke is a live BROWSER session. Devise serialises a
    # session as the user id plus `authenticatable_salt`, which is a slice of
    # the password hash, and this app has no session-version column and no
    # server-side session store (the session is a signed cookie). The only
    # lever that would invalidate other browsers is changing the password,
    # which is not ours to change. Remember-me is cleared, which is the part
    # that survives a closed browser; the accepting browser is signed in again
    # by InvitesController so the person who just pressed the button is not
    # thrown out.
    def revoke_credentials!(user)
      AccessToken.where(user_id: user.id).delete_all
      McpToken.where(user_id: user.id).delete_all
      Accounts::Purge::OauthAccessGrant.where(resource_owner_id: user.id).delete_all
      Accounts::Purge::OauthAccessToken.where(resource_owner_id: user.id).delete_all

      user.forget_me!

      %i[access_token access_tokens mcp_tokens].each { |name| user.association(name).reset }
    end

    # Every reason a move is refused, each with the sentence the invitee sees.
    # They are all about the account being LEFT: the team doing the inviting
    # has already been checked (it had a seat, and it paid for it).
    def assert_movable!(user:, from:, to:)
      raise Refused, I18n.t('invite_move_same_account') if from.id == to.id

      unless from.customer? && from.linked_account_account.blank?
        raise Refused, I18n.t('invite_move_not_a_personal_account')
      end

      if User.where(account_id: from.id).active.where.not(id: user.id).exists?
        raise Refused, I18n.t('invite_move_other_members')
      end

      raise Refused, I18n.t('invite_move_paid_subscription') if Plans.live_subscription?(from)

      true
    end

    # document_metadata is one row per (account, file checksum) — a unique
    # index — and two accounts that have both signed the same file each hold
    # their own. Re-parenting the incoming one would collide with the row
    # already there and take the whole move down, so the incoming duplicate
    # is dropped first: the surviving row says exactly the same thing about
    # exactly the same bytes.
    def drop_duplicate_document_metadata!(from, to)
      existing = DocumentMetadata.where(account_id: to.id).pluck(:blob_checksum)

      return if existing.empty?

      DocumentMetadata.where(account_id: from.id, blob_checksum: existing).delete_all
    end

    # Folders are merged by NAME, because every account has a "Default" folder
    # and two of them in one account would be a confusing mess. A folder whose
    # name already exists in the team hands its templates to the folder that
    # is already there and is then deleted; a folder with a new name simply
    # changes hands.
    def merge_folders!(from, to)
      existing = to.template_folders.index_by(&:name)

      from.template_folders.each do |folder|
        twin = existing[folder.name]

        if twin
          Template.where(folder_id: folder.id).update_all(folder_id: twin.id)
          TemplateFolder.where(parent_folder_id: folder.id).update_all(parent_folder_id: twin.id)
          folder.destroy!
        else
          folder.update!(account_id: to.id)
          existing[folder.name] = folder
        end
      end
    end
  end
end
