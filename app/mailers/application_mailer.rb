# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: 'EsignCenter <noreply@esigncenter.com>'
  layout 'mailer'

  register_interceptor ActionMailerConfigsInterceptor
  register_interceptor HtmlToPlainTextInterceptor
  register_preview_interceptor HtmlToPlainTextInterceptor

  register_observer ActionMailerEventsObserver

  helper_method :platform_notice?, :mail_greeting

  before_action do
    ActiveStorage::Current.url_options = Docuseal.default_url_options
  end

  after_action :set_message_metadata
  after_action :set_message_uuid
  after_action :set_mail_account_header

  def default_url_options
    Docuseal.default_url_options.merge(host: ENV.fetch('EMAIL_HOST', Docuseal.default_url_options[:host]))
  end

  def set_message_metadata
    message.instance_variable_set(:@message_metadata, @message_metadata || {})
  end

  def set_message_uuid
    uuid = SecureRandom.uuid
    message['X-Message-Uuid'] = uuid
    message['X-PM-Metadata-message-uuid'] = uuid
  end

  def assign_message_metadata(tag, record)
    @message_metadata = (@message_metadata || {}).merge(
      'tag' => tag,
      'record_id' => record.id,
      'record_type' => record.class.name
    )
  end

  def put_metadata(attrs)
    @message_metadata = (@message_metadata || {}).merge(attrs)
  end

  protected

  # The account a message belongs to, named by every mailer that writes to a
  # customer. It does two things, and the second one is why it is called even
  # by mailers with nothing to configure:
  #
  #   * the interceptor resolves the right outgoing server from it;
  #   * it makes the message TRACKABLE. Delivery tracking hangs off
  #     `@message_metadata` (ActionMailerEventsObserver writes one `send` row
  #     per recipient, and PostmarkWebhooks attributes every bounce, complaint
  #     and open back to it). Until Session 10 the SaaS lifecycle mail — the
  #     dunning letters, the suspension notice, invitations, quota warnings —
  #     set no metadata at all, so no send row was written and every Postmark
  #     event about them was dropped as `{ ignored: true }`: we could suspend
  #     an account on day 14 and not be able to prove the warning was ever
  #     delivered (review 8, C3). Naming the account is now enough, because
  #     that is the record the row is attributed to.
  #
  # A mailer that has already named a more specific record — SubmitterMailer
  # naming the submitter, UserMailer the user — keeps it: whoever calls
  # `assign_message_metadata` is saying "this message is ABOUT this record",
  # and the account is only the fallback.
  def mail_account(account)
    @_mail_account = account

    assign_message_metadata(default_message_tag, account) if account && @message_metadata.blank?

    account
  end

  # "billing_payment_failed", "quota_storage_warning",
  # "account_deletion_reminder_to" — the mailer and the message, which is what
  # a tag is for. Derived rather than typed at eighteen call sites, so a mail
  # added next month is tagged the day it is written.
  def default_message_tag
    "#{self.class.name.underscore.delete_suffix('_mailer')}_#{action_name}"
  end

  # How a platform notice opens, asked by the templates.
  #
  # "Hi Jane," when we know who is reading it, and "Hello," when we do not —
  # a message going to several administrators at once, or to an address with
  # no person behind it. A mailer says who it is writing to by setting
  # `@first_name`; saying nothing means the plain greeting, which is the right
  # answer and never a wrong one.
  #
  # English-only, like every other word in these notices (they are platform
  # mail, not localized signer mail), and escaped by the template like any
  # other customer-supplied string.
  def mail_greeting
    @first_name.present? ? "Hi #{@first_name}," : 'Hello,'
  end

  # The addresses a notice to an account's administrators goes to, and the
  # name it may greet by — one answer for both mailers that fan a notice out
  # this way (BillingMailer#prepare, QuotaMailer#prepare).
  #
  # Every such notice goes to EVERY active administrator in ONE message, so
  # there is a name to use only when there is exactly one of them, which is
  # most accounts. With several admins on the To line "Hi Jane," would be
  # wrong for everybody else reading it, and the greeting stays plain
  # (mail_greeting). Blank means the account has no active administrator and
  # the caller sends nothing.
  def admin_recipients(account)
    admins = account.users.active.admins.to_a

    @first_name = admins.one? ? admins.first.first_name.presence : nil

    admins.map(&:email)
  end

  # Which of the two kinds of mail this is, asked by layouts/mailer.
  #
  # A PLATFORM notice is written by EsignCenter to the people who run an
  # account — billing, the account lifecycle, quota warnings, invitations,
  # operator alerts, the SMTP test — and always carries the product's name,
  # because that is who is writing and the reader has to recognise it.
  #
  # Everything else is the CUSTOMER's own mail to their signers, and an
  # account that has paid for branding removal gets no wordmark and no
  # support line on it. The DocuSeal attribution is a separate thing and is
  # never affected either way.
  def platform_notice?
    false
  end

  private

  def set_mail_account_header
    headers['X-EC-Account-Id'] = @_mail_account.id.to_s if @_mail_account
  end
end
