# frozen_string_literal: true

module ActionMailerEventsObserver
  module_function

  # The metadata a message has to carry before a send row can be written: the
  # tag, and the record the message is ABOUT. It is asked here, and it is asked
  # by ApplicationMailer#set_message_uuid before the Postmark metadata copy
  # goes on the message at all — one predicate, so the stamp that invites a
  # provider callback and the row that callback is attributed to can never
  # disagree about which mail is tracked (review 2, M4/N2).
  def attributable?(metadata)
    return false if metadata.blank?

    metadata.values_at('tag', 'record_id', 'record_type').all?(&:present?)
  end

  def delivered_email(mail)
    data = mail.instance_variable_get(:@message_metadata)

    return unless attributable?(data)

    tag, emailable_id, emailable_type = data.values_at('tag', 'record_id', 'record_type')

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
