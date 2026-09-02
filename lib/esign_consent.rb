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
    consent_scope(submitter).exists?
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
  # first one's event. One event per human: after a delegation the next
  # person's consent is a new event (consent_scope).
  def record!(submitter, request, version: nil)
    raise StaleVersionError, 'esign_consent_version_stale' unless version == VERSION

    submitter.class.transaction do
      submitter.class.lock.find(submitter.id)

      consent_scope(submitter).first ||
        SubmissionEvents.create_with_tracking_data(submitter, EVENT_TYPE, request, { version: VERSION })
    end
  end

  def require!(submitter)
    raise ConsentRequiredError, 'esign_consent_required' unless consented?(submitter)

    true
  end

  # The consent events that belong to the person holding the form now.
  # Delegation (`delegate_form`) hands the same submitter row to another
  # human — new email, new slug, same row — so only events newer than the
  # latest delegation count; the first person's event stays in the log for
  # the audit trail, which applies exactly this bound to every per-signer
  # event (Submissions::GenerateAuditTrail).
  def consent_scope(submitter)
    events = submitter.submission_events.where(event_type: EVENT_TYPE)
    delegated_at = submitter.submission_events.where(event_type: 'delegate_form').maximum(:event_timestamp)

    return events unless delegated_at

    events.where(SubmissionEvent.arel_table[:event_timestamp].gt(delegated_at))
  end

  private_class_method :consent_scope
end
