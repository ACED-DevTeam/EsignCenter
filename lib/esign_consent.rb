# frozen_string_literal: true

# ESIGN/UETA consent: every human signer explicitly agrees to use electronic
# records and signatures before they can finish signing. The agreement is one
# versioned `esign_consent` submission event carrying the signer's IP, user
# agent and session (see SubmissionEvents.create_with_tracking_data).
#
# Bump VERSION (and EFFECTIVE_DATE) whenever the disclosure text
# (`esign_consent_disclosure_body_html` in config/locales/i18n.yml) changes;
# the version is stored on the event and printed in the audit trail. The form
# sends back the version it displayed, and a consent for another version — or
# for no version at all — is refused (StaleVersionError): a page opened before
# a bump cannot record the new version for a disclosure the signer never saw.
#
# Sender-attested completions (API `completed: true`, signing sessions created
# completed, MCP) have no human signer and are exempt by design: they create
# `api_complete_form` events, never consent events. See docs/esign-consent.md.
module EsignConsent
  VERSION = 'v1'
  EFFECTIVE_DATE = Date.new(2026, 9, 2)
  EVENT_TYPE = 'esign_consent'

  ConsentRequiredError = Class.new(StandardError)
  StaleVersionError = Class.new(StandardError)

  module_function

  def consented?(submitter)
    submitter.submission_events.exists?(event_type: EVENT_TYPE)
  end

  # One consent event per submitter, stamped with the version the signer saw.
  # Returns the (existing or new) event.
  #
  # `version` is the version the form displayed and must equal VERSION. A
  # request without one is stale too (a page loaded before the version field
  # existed saw a text this code can no longer vouch for): refused, and the
  # signer reloads and agrees again.
  #
  # The submitter row is locked while the event is looked up and created, so
  # two requests arriving together (a save-step and a completion, say) still
  # produce exactly one event: the second waits for the lock, then finds the
  # first one's event.
  def record!(submitter, request, version: nil)
    raise StaleVersionError, 'esign_consent_version_stale' unless version == VERSION

    submitter.class.transaction do
      submitter.class.lock.find(submitter.id)

      submitter.submission_events.find_by(event_type: EVENT_TYPE) ||
        SubmissionEvents.create_with_tracking_data(submitter, EVENT_TYPE, request, { version: VERSION })
    end
  end

  def require!(submitter)
    raise ConsentRequiredError, 'esign_consent_required' unless consented?(submitter)

    true
  end
end
