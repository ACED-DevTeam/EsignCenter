# frozen_string_literal: true

module SubmissionEvents
  TRACKING_PARAM_LENGTH = 6
  TRACKING_TYPES = %w[bounce_email complaint_email open_email click_email].freeze

  module_function

  # Shared by customer renderers, including signed PDFs and API event arrays.
  # Recording remains unconditional: abuse protection needs every event.
  def for_display(events, account:)
    return events if Entitlements.allowed?(account, :delivery_tracking)

    events.reject { |event| TRACKING_TYPES.include?(event.event_type) }
  end

  def build_tracking_param(submitter, event_type = 'click_email')
    Base64.urlsafe_encode64(
      Digest::SHA1.digest([submitter.slug, event_type, Rails.application.secret_key_base].join(':'))
    ).first(TRACKING_PARAM_LENGTH)
  end

  # Blank values are dropped so an event never carries an empty `ip` or a nil
  # `uid` — but `false` is an answer, not a blank: the consent event's
  # `pdf_opened: false` says the browser did not report opening the PDF, and that has to
  # survive into the row.
  def create_with_tracking_data(submitter, event_type, request, data = {})
    SubmissionEvent.create!(submitter:, event_type:, data: {
      ip: request.remote_ip,
      ua: request.user_agent,
      sid: request.session.id.to_s,
      uid: request.env['warden'].user(:user)&.id,
      **data
    }.reject { |_key, value| value != false && value.blank? })
  end

  def populate_account_id
    Account.find_each do |account|
      ids = account.submissions.pluck(:id)

      ids.each_slice(10_000).each do |batch|
        SubmissionEvent.where(submission_id: batch).update_all(account_id: account.id)
      end
    end
  end
end
