# frozen_string_literal: true

# The /support form's one output: an email to the support mailbox
# (SupportRequestsController). No copy goes to the person who wrote it — the
# page they land on is the receipt, and mailing a stranger's address back
# would make the form a way to send mail to anybody.
#
# `reply_to` is the requester, so hitting Reply in the mailbox answers them
# without anyone copying an address by hand; `from` stays the platform's own
# so the message is never spoofed as coming from them.
#
# Every FACT about the account in the body is derived on the server from the
# session — the form cannot claim to be a paid customer.
class SupportMailer < ApplicationMailer
  def request_received(name:, email:, topic:, topic_label:, message:, ip:, account_facts: nil)
    @name = name
    @email = email
    @topic_label = topic_label
    @message = message
    @ip = ip
    @account_facts = account_facts

    put_metadata('tag' => 'support_request', 'topic' => topic)

    # A signed-in person's name comes from their profile, which is not held to
    # this form's length rule (SupportRequest#trusted_identity), so the subject
    # trims it rather than carrying an arbitrarily long line into the mailbox.
    mail(to: Docuseal::SUPPORT_EMAIL, reply_to: email,
         subject: "[EsignCenter support] #{topic_label} — #{name.to_s.truncate(SupportRequest::NAME_LIMIT)}")
  end

  private

  # Written by the platform to the platform. The layout signs it with the
  # product's name whatever any customer's branding-removal setting says
  # (ApplicationMailer#platform_notice?).
  def platform_notice?
    true
  end
end
