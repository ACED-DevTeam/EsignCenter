# frozen_string_literal: true

module Submitters
  # Where a reply to this signer's mail is meant to go.
  #
  # Two readers, and they do NOT want the same answer:
  #
  # `header` is what goes on the outgoing mail. A mail header is published to
  # whoever receives it, so it stays conservative and unchanged from before
  # this module existed: the first address the sender actually configured (or
  # the person who sent the document), display name and all — and nothing at
  # all when that address is a no-reply one or when the sender is signing
  # their own document. An account's internal administrator mailbox is never
  # put on an outgoing header nobody asked to publish.
  #
  # `disclosure` is what the ESIGN notice tells the signer to write to about
  # withdrawing consent or asking for a paper copy. That one must name
  # somewhere a person can actually reach, so it skips a no-reply address
  # rather than stopping at it and keeps going to the account's first
  # administrator. It answers with a bare address, because the disclosure
  # prints it as prose.
  #
  # They agree wherever a reachable address is configured, which is the normal
  # case; they differ only when the mail would carry no Reply-To at all —
  # then the header is nil and the disclosure names the administrator (and,
  # failing even that, the caller falls back to platform support).
  module ReplyTo
    module_function

    # The Reply-To for an outgoing mail, or nil for no Reply-To header.
    # `email_config` is the custom email copy the caller is sending under —
    # nil means it has none, and that step is simply skipped.
    def header(submitter, email_config: nil, documents_copy_reply_to: nil)
      value = submitter.preferences['reply_to'].presence
      value ||= documents_copy_reply_to.presence
      value ||= email_config.value['reply_to'].presence if email_config
      value ||= sending_user_address(submitter)

      return nil if value.to_s.match?(SubmitterMailer::NO_REPLY_REGEXP)

      value
    end

    # The bare address the ESIGN disclosure names, or nil when the account has
    # nothing reachable at all.
    def disclosure(submitter)
      account = submitter.submission.account
      config = Accounts.custom_email_config(account, AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY)

      candidates = [submitter.preferences['reply_to'],
                    config&.value&.dig('reply_to'),
                    sending_user_address(submitter),
                    admin_address(account)]

      candidates.filter_map { |candidate| reachable(candidate) }.first
    end

    # `Name <a@b.com>` (the shape a custom reply-to and User#friendly_name
    # take) down to the bare address, and nothing that no-replies.
    def reachable(value)
      address = (value.to_s[/<([^>]+)>/, 1] || value.to_s).strip

      return if address.blank? || address.exclude?('@') || address.match?(SubmitterMailer::NO_REPLY_REGEXP)

      address
    end

    # The person who sent the document, with the `+tag` stripped off their
    # address the way the mailer has always stripped it. Skipped when that
    # person is the signer: replying to yourself reaches nobody new.
    def sending_user_address(submitter)
      user = submitter.submission.created_by_user || submitter.template&.author

      return if user.nil?
      return if user.email == submitter.email

      user.friendly_name.to_s.sub(/\+\w+@/, '@')
    end

    def admin_address(account)
      account.users.active.full_access.admins.order(:id).first&.email
    end

    private_class_method :reachable, :sending_user_address, :admin_address
  end
end
