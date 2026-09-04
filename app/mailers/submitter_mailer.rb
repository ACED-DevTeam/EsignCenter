# frozen_string_literal: true

class SubmitterMailer < ApplicationMailer
  MAX_ATTACHMENTS_SIZE = 10.megabytes
  SIGN_TTL = 1.hour + 20.minutes

  NO_REPLY_REGEXP = /no-?reply@/i

  # `reminder: true` is the nudge sent days later by
  # SendSubmitterInvitationReminderEmailJob. It is the same email in the same
  # layout; only the copy can differ, and only if the customer wrote reminder
  # copy of their own.
  #
  # The order for a reminder, most specific first, and each of subject and
  # body falls through it on its own:
  #
  #   1. this template's reminder copy   (Preferences → Signature request reminder email)
  #   2. the account's reminder copy     (Personalization → Signature Request Reminder Email)
  #   3. the invitation copy of this send — the ad-hoc message typed into the
  #      send dialog, then the per-signer copy, then this template's
  #   4. the account's invitation copy
  #   5. the stock default
  #
  # Steps 3-5 are the ordinary invitation chain untouched, so an account that
  # never wrote reminder copy sends exactly the mail it sends today. The
  # account-wide reminder wording sits ABOVE the invitation copies on purpose
  # (Q1): a customer who writes one sentence for every reminder on the
  # Personalization page expects to see it even on the templates that carry
  # their own signature-request wording, which is most of them.
  #
  # Reminder copy is part of the paid "custom email templates" row, and it is
  # read through the same `custom_email_*` helpers as every other custom
  # wording — so a paid account that downgrades goes quietly back to the
  # default copy with its rows left where they are (D43: inert, not purged).
  def invitation_email(submitter, reminder: false)
    @current_account = submitter.submission.account
    mail_account(@current_account)
    @submitter = submitter

    if submitter.preferences['email_message_uuid']
      @email_message = submitter.account.email_messages.find_by(uuid: submitter.preferences['email_message_uuid'])
    end

    template_submitters_index = @email_message.blank? ? build_submitter_preferences_index(@submitter) : {}
    template_preferences = @submitter.template&.preferences
    reminder_preferences = template_preferences if reminder

    sources = {
      reminder_preferences:,
      reminder_config: reminder ? custom_email_config(AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY) : nil,
      signer_preferences: template_submitters_index[@submitter.uuid],
      template_preferences:,
      invitation_config: custom_email_config(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY)
    }

    @body = invitation_email_copy('body', sources)
    @subject = invitation_email_copy('subject', sources)

    # Still needed below for the reply-to address and as build_invite_subject's
    # last resort; the reminder row wins it when there is one, exactly as the
    # copy chain above does.
    @email_config = sources[:reminder_config] || sources[:invitation_config]

    assign_message_metadata('submitter_invitation', @submitter)

    reply_to = build_submitter_reply_to(@submitter, email_config: @email_config)

    I18n.with_locale(@current_account.locale) do
      subject = build_invite_subject(@subject, @email_config, submitter)

      mail(
        to: @submitter.friendly_name,
        from: from_address_for_submitter(submitter),
        subject:,
        reply_to:
      )
    end
  end

  def completed_email(submitter, user, to: nil)
    @current_account = submitter.submission.account
    mail_account(@current_account)
    @submitter = submitter
    @submission = submitter.submission
    @user = user

    template_preferences = @submission.template&.preferences || {}

    Submissions::EnsureResultGenerated.call(submitter)

    @email_config = custom_email_config(AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY)

    add_completed_email_attachments!(
      submitter,
      with_documents: @email_config&.value&.dig('attach_documents') != false &&
                      template_preferences['completed_notification_email_attach_documents'] != false,
      with_audit_log: @email_config&.value&.dig('attach_audit_log') != false &&
                      template_preferences['completed_notification_email_attach_audit'] != false
    )

    @subject = custom_email_copy(template_preferences, 'completed_notification_email_subject')
    @subject ||= @email_config.value['subject'] if @email_config

    @body = custom_email_copy(template_preferences, 'completed_notification_email_body')
    @body ||= fetch_config_email_body(@email_config, @submitter)

    assign_message_metadata('submitter_completed', @submitter)

    I18n.with_locale(@current_account.locale) do
      subject =
        ReplaceEmailVariables.call(@subject.presence || I18n.t(:template_name_has_been_completed_by_submitters),
                                   submitter:)

      mail(from: from_address_for_submitter(submitter),
           to: to || normalize_user_email(user),
           subject:)
    end
  end

  def declined_email(submitter, user)
    @current_account = submitter.submission.account
    mail_account(@current_account)
    @submitter = submitter
    @submission = submitter.submission
    @user = user

    assign_message_metadata('submitter_declined', @submitter)

    I18n.with_locale(@current_account.locale) do
      mail(from: from_address_for_submitter(submitter),
           to: user.role == 'integration' ? user.friendly_name.sub(/\+\w+@/, '@') : user.friendly_name,
           reply_to: @submitter.friendly_name,
           subject: I18n.t(:name_declined_by_submitter,
                           name: (@submission.name || @submission.template.name).truncate(20),
                           submitter: @submitter.name || @submitter.email || @submitter.phone))
    end
  end

  def documents_copy_email(submitter, to: nil, sig: false)
    @current_account = submitter.submission.account
    mail_account(@current_account)
    @submitter = submitter
    @sig = submitter.signed_id(expires_in: SIGN_TTL, purpose: :download_completed) if sig

    template_preferences = @submitter.template&.preferences || {}

    Submissions::EnsureResultGenerated.call(@submitter)

    @email_config = custom_email_config(AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY)

    add_completed_email_attachments!(
      submitter,
      with_documents: template_preferences['documents_copy_email_attach_documents'] != false &&
                      (@email_config.nil? || @email_config.value['attach_documents'] != false),
      with_audit_log: template_preferences['documents_copy_email_attach_audit'] != false &&
                      (@email_config.nil? || @email_config.value['attach_audit_log'] != false)
    )

    @subject = custom_email_copy(template_preferences, 'documents_copy_email_subject')
    @subject ||= @email_config.value['subject'] if @email_config

    @body = custom_email_copy(template_preferences, 'documents_copy_email_body')
    @body ||= fetch_config_email_body(@email_config, @submitter)

    assign_message_metadata('submitter_documents_copy', @submitter)
    reply_to = build_submitter_reply_to(submitter, email_config: @email_config, documents_copy_email: true)

    I18n.with_locale(@current_account.locale) do
      subject =
        @subject.present? ? ReplaceEmailVariables.call(@subject, submitter:) : I18n.t(:your_document_copy)

      mail(from: from_address_for_submitter(submitter),
           to: to || @submitter.friendly_name,
           reply_to:,
           subject:)
    end
  end

  def otp_verification_email(submitter, locale: nil)
    @current_account = submitter.submission.account
    mail_account(@current_account)
    @submitter = submitter
    @otp_code = EmailVerificationCodes.generate([submitter.email.downcase.strip, submitter.slug].join(':'))

    assign_message_metadata('otp_verification_email', submitter)

    I18n.with_locale(locale || submitter.account.locale) do
      mail(to: submitter.email, subject: I18n.t('email_verification'))
    end
  end

  private

  # Custom email copy is paid-only and read at send time (Accounts.custom_email_*):
  # nil for an unentitled account, so the default copy renders.
  def custom_email_config(key)
    Accounts.custom_email_config(@current_account, key)
  end

  def custom_email_copy(preferences, key)
    Accounts.custom_email_copy(@current_account, preferences, key)
  end

  def build_submitter_reply_to(submitter, email_config: nil, documents_copy_email: nil)
    reply_to = submitter.preferences['reply_to'].presence
    reply_to ||= submitter.template&.preferences&.dig('documents_copy_email_reply_to').presence if documents_copy_email
    reply_to ||= email_config.value['reply_to'].presence if email_config

    if reply_to.blank? && (submitter.submission.created_by_user || submitter.template.author)&.email != submitter.email
      reply_to = (submitter.submission.created_by_user || submitter.template.author)&.friendly_name&.sub(/\+\w+@/, '@')
    end

    return nil if reply_to.to_s.match?(NO_REPLY_REGEXP)

    reply_to
  end

  def add_completed_email_attachments!(submitter, with_audit_log: true, with_documents: true)
    documents = with_documents ? Submitters.select_attachments_for_download(submitter) : []

    filename_format = AccountConfig.find_or_initialize_by(account_id: submitter.account_id,
                                                          key: AccountConfig::DOCUMENT_FILENAME_FORMAT_KEY)&.value

    total_size = 0
    audit_trail_data = nil

    if with_audit_log && submitter.submission.audit_trail.present? && documents.first&.name != 'combined_document'
      audit_trail_data = submitter.submission.audit_trail.download

      total_size = audit_trail_data.size
    end

    total_size = add_attachments_with_size_limit(submitter, documents, total_size, filename_format)

    if audit_trail_data
      audit_trail_filename =
        Submitters.build_document_filename(submitter, submitter.submission.audit_trail.blob, filename_format)

      attachments[audit_trail_filename.tr('"', "'")] = audit_trail_data
    end

    if with_documents
      file_fields = submitter.submission.template_fields.select { |e| e['type'].in?(%w[file payment]) }

      if file_fields.pluck('submitter_uuid').uniq.size == 1
        storage_attachments =
          submitter.attachments.where(uuid: submitter.values.values_at(*file_fields.pluck('uuid')).flatten)

        add_attachments_with_size_limit(submitter, storage_attachments, total_size)
      end
    end

    documents
  end

  def normalize_user_email(user)
    user.role == 'integration' ? user.friendly_name.sub(/\+\w+@/, '@') : user.friendly_name
  end

  def build_invite_subject(subject, email_config, submitter)
    if email_config || subject
      ReplaceEmailVariables.call(subject || email_config.value['subject'], submitter:)
    elsif submitter.with_signature_fields?
      I18n.t(:you_are_invited_to_sign_a_document)
    else
      I18n.t(:you_are_invited_to_submit_a_form)
    end
  end

  def build_submitter_preferences_index(submitter)
    submitter.template&.preferences&.dig('submitters').to_a.index_by { |e| e['uuid'] }
  end

  def add_attachments_with_size_limit(submitter, storage_attachments, current_size, filename_format = nil)
    total_size = current_size

    storage_attachments.each do |attachment|
      total_size += attachment.byte_size

      break if total_size >= MAX_ATTACHMENTS_SIZE

      filename = Submitters.build_document_filename(submitter, attachment.blob, filename_format)
      attachments[filename.to_s.tr('"', "'")] = attachment.download
    end

    total_size
  end

  def from_address_for_submitter(submitter)
    if submitter.submission.source.in?(%w[api embed]) &&
       (from_email = AccountConfig.find_by(account: submitter.account, key: 'integration_from_email')&.value.presence)
      user = submitter.account.users.find_by(email: from_email)

      put_metadata('from_user_id' => user.id)

      from_email
    else
      user = submitter.submission.created_by_user || submitter.submission.template.author

      put_metadata('from_user_id' => user.id)

      user.friendly_name
    end
  end

  # One walk of the reminder/invitation fallback order documented on
  # #invitation_email, for one field ('subject' or 'body'). Subject and body
  # walk it separately, so a reminder row that carries only a subject leaves
  # the body to the wording below it rather than blanking it.
  def invitation_email_copy(field, sources)
    custom_email_copy(sources[:reminder_preferences], "invitation_reminder_email_#{field}") ||
      fetch_config_email_value(sources[:reminder_config], field) ||
      @email_message&.public_send(field).presence ||
      custom_email_copy(sources[:signer_preferences], "request_email_#{field}") ||
      custom_email_copy(sources[:template_preferences], "request_email_#{field}") ||
      fetch_config_email_value(sources[:invitation_config], field)
  end

  def fetch_config_email_value(email_config, field)
    email_config ? email_config.value[field].presence : nil
  end

  def fetch_config_email_body(email_config, _submitter = nil)
    fetch_config_email_value(email_config, 'body')
  end
end
