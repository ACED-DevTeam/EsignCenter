# frozen_string_literal: true

module Submitters
  # Where a reply to this signer's mail actually lands.
  #
  # One resolver, two readers: SubmitterMailer puts the answer in the
  # invitation's Reply-To header, and the ESIGN disclosure prints it as the
  # address to write to about withdrawing consent or asking for paper. They
  # must not be able to drift apart — a disclosure naming a mailbox the
  # invitation never used would be telling the signer something untrue.
  #
  # The chain, most specific first:
  #
  #   1. the reply-to set on this signer (`preferences['reply_to']`)
  #   2. for a documents-copy mail only, the template's own copy address —
  #      passed in by the caller, because reading it is entitlement-gated
  #      (SubmitterMailer#template_documents_copy_reply_to and D43)
  #   3. the account's custom email copy for this mail (paid; the invitation
  #      copy when the caller names no other)
  #   4. the person who sent the document — skipped when that is the signer
  #      themselves, because a self-signer replying to their own address
  #      reaches nobody new, and with the `+tag` stripped off the address the
  #      way the mailer has always stripped it
  #   5. the account's first active, full-access administrator
  #
  # A no-reply address is skipped at every step rather than ending the chain:
  # both readers need somewhere a person can actually write to. nil when the
  # account has nothing reachable at all; each caller decides what to do then.
  module ReplyTo
    INVITATION = :invitation

    module_function

    def call(submitter, email_config: INVITATION, documents_copy_reply_to: nil)
      account = submitter.submission.account
      email_config = invitation_config(account) if email_config == INVITATION

      candidates = [
        submitter.preferences['reply_to'],
        documents_copy_reply_to,
        email_config&.value&.dig('reply_to'),
        sending_user_address(submitter),
        admin_address(account)
      ]

      candidates.filter_map { |candidate| reachable(candidate) }.first
    end

    # `Name <a@b.com>` (the shape a custom reply-to and User#friendly_name
    # take) down to the bare address, and nothing that no-replies.
    def reachable(value)
      address = (value.to_s[/<([^>]+)>/, 1] || value.to_s).strip

      return if address.blank? || address.exclude?('@') || address.match?(SubmitterMailer::NO_REPLY_REGEXP)

      address
    end

    def sending_user_address(submitter)
      user = submitter.submission.created_by_user || submitter.template&.author

      return if user.nil?
      # The sender signing their own document: their own address is not a
      # reply address for them, so the chain moves on to the administrator.
      return if user.email == submitter.email

      user.friendly_name.to_s.sub(/\+\w+@/, '@')
    end

    def invitation_config(account)
      Accounts.custom_email_config(account, AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY)
    end

    def admin_address(account)
      account.users.active.full_access.admins.order(:id).first&.email
    end

    private_class_method :reachable, :sending_user_address, :invitation_config, :admin_address
  end
end
