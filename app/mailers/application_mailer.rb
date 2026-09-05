# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: 'EsignCenter <noreply@esigncenter.com>'
  layout 'mailer'

  register_interceptor ActionMailerConfigsInterceptor
  register_interceptor HtmlToPlainTextInterceptor
  register_preview_interceptor HtmlToPlainTextInterceptor

  register_observer ActionMailerEventsObserver

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

  private

  def set_mail_account_header
    headers['X-EC-Account-Id'] = @_mail_account.id.to_s if @_mail_account
  end
end
