# frozen_string_literal: true

# ESIGN/UETA consent: every human signer explicitly agrees to use electronic
# records and signatures before they can finish signing. The agreement is one
# versioned `esign_consent` submission event carrying the signer's IP, user
# agent and session (see SubmissionEvents.create_with_tracking_data).
#
# Bump VERSION (and EFFECTIVE_DATE) whenever the disclosure text
# (`esign_consent_disclosure_body_html` in config/locales/i18n.yml) changes;
# the version is stored on the event and printed in the audit trail.
#
# Sender-attested completions (API `completed: true`, signing sessions created
# completed, MCP) have no human signer and are exempt by design: they create
# `api_complete_form` events, never consent events. See docs/esign-consent.md.
module EsignConsent
  VERSION = 'v1'
  EFFECTIVE_DATE = Date.new(2026, 9, 2)
  EVENT_TYPE = 'esign_consent'

  ConsentRequiredError = Class.new(StandardError)

  module_function

  def consented?(submitter)
    submitter.submission_events.exists?(event_type: EVENT_TYPE)
  end

  # Idempotent: one consent event per submitter, stamped with the version the
  # signer saw. Returns the (existing or new) event.
  def record!(submitter, request)
    submitter.submission_events.find_by(event_type: EVENT_TYPE) ||
      SubmissionEvents.create_with_tracking_data(submitter, EVENT_TYPE, request, { version: VERSION })
  end

  def require!(submitter)
    raise ConsentRequiredError, 'esign_consent_required' unless consented?(submitter)

    true
  end
end
