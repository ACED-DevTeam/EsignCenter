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
    #   * the platform's OWN letters to the account being left — the dunning
    #     notices, the suspension warnings, the quota letters. Their delivery
    #     rows are `EmailEvent`s like a signer's, but with
    #     `emailable_type: 'Account'` (Session 10, D1), and they are the
    #     record of what WE sent THAT COMPANY. See MOVED_SCOPES.
    #   * legal_acceptances DO move (Session 9 phase A, review 1). The row is
    #     the person's agreement to the Terms and the Privacy Policy, and it
    #     belongs to the person rather than to the company they were in when
    #     they made it — leaving it behind would strand it under an account
    #     that is about to be archived and purged, taking the only record of
    #     what they agreed to with it. Moved by account like everything else
    #     here, which is right: a move is only ever offered to somebody who is
    #     alone in their account.
    MOVED_TABLES = [Template, TemplateSharing, TemplateVersion, Submission, Submitter, SubmissionEvent,
                    DocumentMetadata, EmailMessage, EmailEvent, SearchEntry, LegalAcceptance].freeze

    # Where "everything on this account" is too much (session 10, seam M2).
    #
    # `email_events` holds two different things behind one account_id. A row
    # about a SIGNER is the delivery history of a document — it belongs with
    # the document, and the document is moving. A row about the ACCOUNT is the
    # platform's own mail to that company's administrators: a dunning letter,
    # a suspension notice, a quota warning. Moving those handed the TEAM the
    # old account's mail history, addressed to people who are not in it — and
    # then put them out of the old account's reach forever, because
    # `Purge#delete_projections!` finds `EmailEvent` by `account_id` and those
    # rows no longer carried it. The retention promise says that data is
    # destroyed; it was quietly surviving under a different tenant.
    #
    # `EmailMessage` needs no scope: it is the body of a mail a USER composed
    # and has no platform-mail equivalent.
    # Submitter rows follow the documents; Template rows are a moved template's own
    # share-link verification mail (TemplateMailer), so they follow it too. Account
    # rows are the platform's letters to the OLD company and stay for its purge.
    MOVED_SCOPES = { EmailEvent => { emailable_type: %w[Submitter Template] } }.freeze

    module_function

    # Nothing outside the lock decides anything (review 7, D50 D2).
    #
    # This used to read `user.account` and run every eligibility check BEFORE
    # it opened its transaction, and the acceptance door above it locked only
    # the INVITATION row. So one person holding invitations from two different
    # teams could accept both at once and have them not collide at all: two
    # different invitation rows, two different locks, and both passes agreeing
    # that the person was alone in account A. The first moved the documents
    # into B; the second found nothing left to move (`where(account_id: A)`
    # matched no rows by then) and moved only the PERSON, into C. The person
    # ended in C with every document they own sitting permanently inside B — a
    # tenant they are not a member of, whose administrators now own their work
    # — and both AccountMove rows recorded a success.
    #
    # So the transaction is opened FIRST and the user row is locked and re-read
    # inside it, which is what serialises the two acceptances: the second one
    # waits for the first to commit and then reads the world the first one
    # left. `expected_from_id` is the account the CALLER validated against —
    # the account the invitee was shown, before any lock — and comparing it
    # against the re-read row is the whole refusal: a person who is no longer
    # in the account this call was authorized over is not moved out of
    # whatever account they are in now.
    #
    # The source account is locked too, because every remaining check reads it
    # (its kind, its members, its subscription, its lifecycle state) and a
    # purge claim or a deletion landing between the check and the write is the
    # worst of them (D5, `assert_source_writable!`): documents that were meant
    # to be destroyed surviving inside another tenant.
    #
    # `from` is that authorizing account: the one the invitee was shown on the
    # join screen, read before any lock was taken. It defaults to whatever the
    # user object in hand says, which is the same thing for a caller that has
    # not reloaded the row; passing it explicitly is what keeps the comparison
    # honest for a caller that has (AccountInvites.accept_move!).
    def call(user:, to:, role: nil, from: user.account)
      expected_from_id = from.id

      ApplicationRecord.transaction do
        user.lock!

        raise Refused, I18n.t('invite_move_already_moved') if user.account_id != expected_from_id

        # The same account, now read under its own lock: from here on `from`
        # is the database's answer rather than the caller's.
        from = user.account.lock!

        assert_movable!(user:, from:, to:)

        merge_folders!(from, to)
        drop_duplicate_document_metadata!(from, to)
        drop_untouched_starters!(from, to)
        MOVED_TABLES.each do |model|
          model.where(account_id: from.id).where(MOVED_SCOPES.fetch(model, {})).update_all(account_id: to.id)
        end

        # The seat they take in the team is a full one: whatever their old
        # account thought of them, they are a member here now.
        #
        # `session_version` goes up in the same write, and that is what ends
        # every browser session minted while they were in the old account
        # (User#authenticatable_salt). It is bumped HERE, inside the lock and
        # the transaction, so a session cannot outlive the move by even the
        # width of a second write — and if anything below raises, the rollback
        # takes the bump with it and nobody is signed out of a move that never
        # happened.
        user.update!(account: to, role: role.presence || user.role, read_only_at: nil,
                     session_version: user.session_version + 1)

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
    # Live BROWSER sessions are ended by the `session_version` bump in `call`
    # rather than here, because they are ended by a WRITE rather than by a
    # delete: Devise serialises a session as the user id plus
    # `authenticatable_salt`, this app appends `users.session_version` to that
    # salt (User#authenticatable_salt), and Warden re-compares it out of the
    # database on every request. One number changing inside the move's
    # transaction is every outstanding session cookie and every remember-me
    # cookie refused at once — including cookies on machines nobody here can
    # see. Remember-me is still cleared below as well, because
    # `remember_created_at` is a second, independent reason for Devise to
    # refuse a cookie and clearing it costs nothing. The accepting browser is
    # signed in again by InvitesController, after the bump, so the person who
    # just pressed the button is not thrown out by their own click.
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
    #
    # Called only from inside `call`, under the user's and the source
    # account's row locks, on rows those locks have just re-read. Everything
    # here is a fact that can change between the page and the button, and
    # several of them are facts another worker changes — a purge claiming the
    # account, an administrator asking for deletion, a failed payment
    # suspending it — so asking them anywhere else is asking them about a
    # world that has already moved on.
    def assert_movable!(user:, from:, to:)
      raise Refused, I18n.t('invite_move_same_account') if from.id == to.id

      unless from.customer? && from.linked_account_account.blank?
        raise Refused, I18n.t('invite_move_not_a_personal_account')
      end

      assert_source_writable!(from)

      if User.where(account_id: from.id).active.where.not(id: user.id).exists?
        raise Refused, I18n.t('invite_move_other_members')
      end

      raise Refused, I18n.t('invite_move_paid_subscription') if Plans.live_subscription?(from)

      true
    end

    # The lifecycle of the account being LEFT (review 7, D50 D5).
    #
    # A move is the biggest write this app makes on an account: every template,
    # every document, every folder changes tenant, and the account is closed
    # behind them. None of that may happen out of an account that is not
    # allowed to be written at all.
    #
    # Two of these are data-loss questions rather than politeness. An account
    # whose purge has been CLAIMED is being emptied right now, in another
    # process, outside any lock this request could have waited on — a move
    # racing it would carry the surviving half of somebody's data into a
    # different tenant while the rest of it is deleted. And an account with a
    # deletion pending is under a promise: the customer said "destroy all of
    # this", and honouring a move would leave every document they asked us to
    # delete alive inside a team instead.
    #
    # The other two are the contract. A suspended account is read-only for a
    # reason its owner has to settle first (an unpaid card, an operator
    # freeze), and an already-archived account is over. Asked in this order
    # because the states overlap and the invitee deserves the specific
    # sentence: a purge claim also reads as read-only, and a pending deletion
    # is a suspension with `reason: 'deletion'` behind it.
    #
    # The predicates are the app's own — `Account#purge_claimed?`,
    # `Account#pending_deletion?`, `AccountStates.read_only?` — never a second
    # opinion written here, so a state added to any of them is refused here
    # from the day it exists.
    def assert_source_writable!(from)
      raise Refused, I18n.t('invite_move_source_purging') if from.purge_claimed?
      raise Refused, I18n.t('invite_move_source_archived') if from.archived_at.present?
      raise Refused, I18n.t('invite_move_source_pending_deletion') if from.pending_deletion?
      raise Refused, I18n.t('invite_move_source_frozen') if AccountStates.read_only?(from)

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

    # Both self-serve doors seed a brand-new account with the same four
    # ready-made documents (StarterTemplates), so somebody who signed up
    # alone, never touched theirs and then joined a team that also signed up
    # self-serve used to land the team with eight cards, four of them the same
    # name twice, and nothing on the card to tell one from the other (session
    # 10, seam L1).
    #
    # The incoming duplicates are dropped, and only those: still carrying the
    # starter marker, never used — no submission was ever made from them — and
    # named the same as a starter the team already holds. A starter the person
    # actually sent is their work and travels with them like anything else,
    # and so is one they renamed, because the NAME is what makes it a
    # duplicate on the screen this is about. The information lost is zero: the
    # card that survives is the same document.
    def drop_untouched_starters!(from, to)
      names = StarterTemplates.marked(Template.where(account_id: to.id)).pluck(:name)

      return if names.empty?

      StarterTemplates.marked(Template.where(account_id: from.id, name: names))
                      .where(shared_link: false).where.missing(:submissions).each(&:destroy!)
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
