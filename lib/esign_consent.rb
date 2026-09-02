# frozen_string_literal: true

# ESIGN/UETA consent: every human signer explicitly agrees to use electronic
# records and signatures before they can finish signing. The agreement is one
# versioned `esign_consent` submission event carrying the signer's IP, user
# agent and session (see SubmissionEvents.create_with_tracking_data) plus the
# locale the disclosure was shown in and a SHA-256 of that disclosure text,
# so the exact words the person agreed to stay answerable inside the product.
#
# Bump VERSION (and EFFECTIVE_DATE) the first time the disclosure text
# (`esign_consent_disclosure_body_html` in config/locales/i18n.yml) changes
# after a production consent has been recorded under the current version, and
# archive the superseded text of every locale under
# config/locales/esign_disclosures/<old-version>.yml (see disclosure_text).
# The version is stored on the event and printed in the audit trail. The form
# sends back the version it displayed, and a consent for another version — or
# for no version at all — is refused (StaleVersionError): a page opened before
# a bump cannot record the new version for a disclosure the signer never saw.
#
# Sender-attested completions (API `completed: true`, signing sessions created
# completed) have no human signer and are exempt by design: they create
# `api_complete_form` events, never consent events. See docs/esign-consent.md.
module EsignConsent
  VERSION = 'v1'
  EFFECTIVE_DATE = Date.new(2026, 9, 2)
  EVENT_TYPE = 'esign_consent'
  DISCLOSURE_KEY = 'esign_consent_disclosure_body_html'
  # Superseded disclosures live in config/locales/esign_disclosures/<version>.yml
  # as `<locale>: { esign_disclosure_archive: { <version>: <body html> } }` —
  # Rails loads that folder with the other locale files, and the scope keeps
  # an old text from ever shadowing the live DISCLOSURE_KEY.
  ARCHIVE_SCOPE = 'esign_disclosure_archive'
  VERSION_FORMAT = /\Av\d+\z/

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
  # `locale` is the locale the page rendered the disclosure in (the form sends
  # it back with the consent); without one, or with one this product does not
  # speak, the request's locale stands in. The event stores that locale and
  # the digest of the disclosure text in it — computed here from the locale
  # data, never taken from the client.
  #
  # The submitter row is locked while the event is looked up and created, so
  # two requests arriving together (a save-step and a completion, say) still
  # produce exactly one event: the second waits for the lock, then finds the
  # first one's event. One event per human: after a delegation the next
  # person's consent is a new event (consent_scope).
  def record!(submitter, request, version: nil, locale: nil)
    raise StaleVersionError, 'esign_consent_version_stale' unless version == VERSION

    locale = normalize_locale(locale) || normalize_locale(I18n.locale) || I18n.default_locale.to_s

    submitter.class.transaction do
      submitter.class.lock.find(submitter.id)

      consent_scope(submitter).first ||
        SubmissionEvents.create_with_tracking_data(submitter, EVENT_TYPE, request, {
                                                     version: VERSION,
                                                     locale:,
                                                     disclosure_sha256: disclosure_sha256(version: VERSION, locale:)
                                                   })
    end
  end

  def require!(submitter)
    raise ConsentRequiredError, 'esign_consent_required' unless consented?(submitter)

    true
  end

  # The base locales the disclosure exists in (`en`, `fr`, ...). Regional
  # variants (`en-GB`, `fr-FR`) are aliases of their base locale in
  # config/locales/i18n.yml, so the base locale names the text a page showed.
  def locales
    I18n.available_locales.map { |l| l.to_s.split('-').first }.uniq
  end

  def normalize_locale(locale)
    base = locale.to_s.split('-').first.to_s.downcase

    base if locales.include?(base)
  end

  # The disclosure body (the HTML the modal renders) for a version and locale:
  # the live locale key for the current version, the archive scope for a
  # superseded one. nil when that pair was never published.
  def disclosure_text(version:, locale:)
    locale = normalize_locale(locale)

    return if locale.nil? || !version.to_s.match?(VERSION_FORMAT)

    key = version == VERSION ? DISCLOSURE_KEY : "#{ARCHIVE_SCOPE}.#{version}"

    I18n.t(key, locale:, fallback: false, raise: true)
  rescue I18n::MissingTranslationData
    nil
  end

  # What a consent event's `disclosure_sha256` must equal for a later reader to
  # trust that the archived text is the one the signer saw.
  def disclosure_sha256(version:, locale:)
    text = disclosure_text(version:, locale:)

    Digest::SHA256.hexdigest(text) if text
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
