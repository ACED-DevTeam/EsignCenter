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
        MOVED_TABLES.each { |model| model.where(account_id: from.id).update_all(account_id: to.id) }

        # The seat they take in the team is a full one: whatever their old
        # account thought of them, they are a member here now.
        user.update!(account: to, role: role.presence || user.role, read_only_at: nil)

        from.update!(archived_at: Time.current) if from.archived_at.blank?

        AccountMove.create!(from_account: from, to_account: to, user:)
      end

      user
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

      raise Refused, I18n.t('invite_move_paid_subscription') if Plans.paid_subscription?(from)

      true
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
