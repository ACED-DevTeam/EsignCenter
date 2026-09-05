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

  def mail_account(account)
    @_mail_account = account
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
