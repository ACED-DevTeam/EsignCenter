# frozen_string_literal: true

module ActionMailerEventsObserver
  module_function

  def delivered_email(mail)
    data = mail.instance_variable_get(:@message_metadata)

    return if data.blank?

    tag, emailable_id, emailable_type = data.values_at('tag', 'record_id', 'record_type')

    return if tag.blank? || emailable_type.blank? || emailable_id.blank?

    message_id = fetch_message_id(mail)

    all_emails(mail).each do |email|
      EmailEvent.create!(
        tag:,
        message_id:,
        emailable_id:,
        emailable_type:,
        event_type: :send,
        email:,
        data: { from: mail.from, method: mail.delivery_method.class.name.underscore },
        event_datetime: Time.current
      )
    end

    # Postmark can be back with a bounce before this observer has written the
    # send row above — it runs after the message has already been handed over.
    # Anything that arrived early was parked rather than dropped (review 8,
    # D8), and this is the moment it can be attributed.
    PostmarkWebhooks.attribute_pending!(message_id)
  rescue StandardError => e
    ErrorReport.error(e)

    raise if Rails.env.local?
  end

  def fetch_message_id(mail)
    mail['X-Message-Uuid']&.value || SecureRandom.uuid
  end

  def all_emails(mail)
    mail.to.to_a + mail.cc.to_a + mail.bcc.to_a
  end
end
