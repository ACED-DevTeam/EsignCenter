# frozen_string_literal: true

# ESIGN/UETA consent: every human signer explicitly agrees to use electronic
# records and signatures before they can finish signing. The agreement is one
# versioned `esign_consent` submission event carrying the signer's IP, user
# agent and session (see SubmissionEvents.create_with_tracking_data) plus the
# locale the disclosure was shown in and a SHA-256 of that disclosure text,
# so the exact words the person agreed to stay answerable inside the product.
#
# The digest fingerprints the TEMPLATE — the locale string with its
# `%{sender_name}` / `%{sender_email}` / `%{product_name}` placeholders still
# in it — not the filled-in text the signer read on screen. That way one
# digest per version and locale answers "which disclosure was this?", and the
# details that differ from sender to sender are stored beside it on the event
# (`sender_name`, `sender_email`), taken from the server, never the browser.
# `disclosure_html` fills the placeholders in for display.
#
# One thing does change the template itself: a person signing their own
# document is shown the self-signing variant (self_signing_body), so the event
# carries a `self_signing` flag and a digest of that variant. Version, locale
# and flag together name one exact text, which is all a later reader needs.
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
  VERSION = 'v2'
  EFFECTIVE_DATE = Date.new(2026, 9, 5)
  EVENT_TYPE = 'esign_consent'
  DISCLOSURE_KEY = 'esign_consent_disclosure_body_html'
  # Superseded disclosures live in config/locales/esign_disclosures/<version>.yml
  # as `<locale>: { esign_disclosure_archive: { <version>: <body html> } }` —
  # Rails loads that folder with the other locale files, and the scope keeps
  # an old text from ever shadowing the live DISCLOSURE_KEY.
  ARCHIVE_SCOPE = 'esign_disclosure_archive'
  VERSION_FORMAT = /\Av\d+\z/
  # The placeholder that marks a "write to the sender" paragraph, spelled out
  # so it is not read as a format token (self_signing_body).
  SENDER_EMAIL_PLACEHOLDER = ['%', '{sender_email}'].join.freeze

  ConsentRequiredError = Class.new(StandardError)
  StaleVersionError = Class.new(StandardError)
  # A locale refusal is not a stale version, and telling a signer to reload
  # because "the disclosure was updated" when nothing was updated is a lie in
  # the one place the product cannot afford one. Its own error, its own key.
  LocaleInvalidError = Class.new(StandardError)

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
  # `locale` and `locale_token` are ONE thing, and it is not "the language the
  # signer's browser asked for". The token is this server's own HMAC over
  # (this signer's slug, this VERSION, this locale), minted by the page that
  # rendered the disclosure — so the pair says exactly, and only:
  #
  #     this server rendered this disclosure, in this language, for this signer.
  #
  # It deliberately does NOT say "this is the page the box was ticked on":
  # nothing in a browser can prove that, and the record never claims it. What
  # it does buy is that the language stamped on the evidence — and therefore
  # the disclosure text the audit trail reproduces years later — is a language
  # this server really published to this person, not one the client picked at
  # completion time. Comparing the posted locale with the locale of THIS
  # request would not do, because the completion request's locale is itself
  # client-controlled (`?lang=` and Accept-Language, ApplicationController#
  # with_browser_locale): a signer could post `lang=ar` beside
  # `esign_consent_locale=ar` against an English page and have the Arabic
  # disclosure digested and reproduced as the text they read, while an honest
  # `/s/:slug?lang=fr` link was refused because the form posts to a bare
  # `/s/:slug`. The token survives that trip and cannot be minted by a browser.
  #
  # `require_locale:` is what separates the two kinds of caller.
  #
  #   * An INTERACTIVE consent — one that came from a signing page, which is
  #     every consent the product actually records (Submitters::SubmitValues,
  #     for both the form step and the invite request) — passes it. The pair
  #     is then mandatory: omitted, blank, unsigned, forged, or naming a
  #     language this product does not speak, all refuse with
  #     LocaleInvalidError and write nothing. Without that, a page could omit
  #     the pair and silently fall through to the request locale, which is the
  #     `?lang=`/Accept-Language value the client chose — the exact hole the
  #     token exists to close.
  #   * A SERVER-SIDE caller with no page behind it (record! straight from
  #     Ruby) has no token to offer and stands on this request's own rendered
  #     locale. That path is the default, and it is server-side by
  #     construction: no controller reaches it.
  #
  # `sender_name` and `sender_email` are the details the disclosure named as
  # the sender. They are read off the server's own records here, so the event
  # reproduces the filled-in text the signer read, not just the template.
  #
  # `sender_digest` binds the recorded sender to the sender the page actually
  # showed: SHA-256 of the name and address as rendered. The server recomputes
  # it from its own values and refuses a consent that does not match, exactly
  # as it refuses a stale version — otherwise an account renamed (or a
  # reply-to changed) while the modal sat open would record one sender against
  # a disclosure that named another. A request without a digest is refused for
  # the same reason a request without a version is: nothing vouches for what
  # that page put in front of the signer.
  #
  # `pdf_opened` is the one client attestation on the event, and it has THREE
  # answers, not two:
  #
  #   * `true`  — the browser reported following the "View this document as a
  #     PDF" link before the box was ticked;
  #   * `false` — a link was offered and the browser reported it unfollowed;
  #   * ABSENT  — the key is not on the event at all. That is what a page with
  #     no link to offer posts (a submission whose documents cannot be served
  #     as one PDF), and what every consent recorded before this product asked
  #     the question carries.
  #
  # The server cannot prove any of it — a browser can post anything — so it is
  # stored as what it is, the page's own claim, and the audit trail prints it
  # as such, with a third line for the absent case. Writing `false` where the
  # question was never put would assert, in signed evidence, that a person
  # declined to open a link they were never shown.
  #
  # The submitter row is locked while the event is looked up and created, so
  # two requests arriving together (a save-step and a completion, say) still
  # produce exactly one event: the second waits for the lock, then finds the
  # first one's event. One event per human: after a delegation the next
  # person's consent is a new event (consent_scope).
  def record!(submitter, request, version: nil, locale: nil, locale_token: nil, pdf_opened: nil, sender_digest: nil,
              require_locale: false)
    raise StaleVersionError, 'esign_consent_version_stale' unless version == VERSION

    name = sender_name(submitter)
    email = sender_email(submitter)

    raise StaleVersionError, 'esign_consent_version_stale' unless sender_digest == digest_of(name, email)

    locale = resolve_locale!(submitter, locale, locale_token, require_locale:)
    self_signing = self_signing?(submitter)

    data = {
      version: VERSION,
      locale:,
      self_signing:,
      disclosure_sha256: disclosure_sha256(version: VERSION, locale:, self_signing:),
      sender_name: name,
      sender_email: email
    }

    data[:pdf_opened] = pdf_opened.to_s == 'true' unless pdf_opened.nil?

    submitter.class.transaction do
      submitter.class.lock.find(submitter.id)

      consent_scope(submitter).first ||
        SubmissionEvents.create_with_tracking_data(submitter, EVENT_TYPE, request, data)
    end
  end

  # Which language this consent is filed under (see record! for the rule).
  # An interactive caller must hand over a signed pair; a server-side one
  # stands on the locale this request rendered in.
  def resolve_locale!(submitter, locale, token, require_locale: false)
    return verified_locale!(submitter, locale, token) if locale.presence
    raise LocaleInvalidError, 'esign_consent_locale_invalid' if require_locale

    rendered_locale
  end

  # The locale the page says it rendered the disclosure in, accepted only on
  # this server's own signature over it (see record!). Returns the normalized
  # locale; raises for a locale we do not speak, a missing token or a token
  # that is not ours.
  def verified_locale!(submitter, locale, token)
    expected = locale_token(submitter, locale)

    unless expected && token.present? &&
           ActiveSupport::SecurityUtils.secure_compare(expected, token.to_s)
      raise LocaleInvalidError, 'esign_consent_locale_invalid'
    end

    normalize_locale(locale)
  end

  # The signing page's answer to "which language was this disclosure rendered
  # in?", signed so the completion request cannot substitute another. Bound to
  # the signer (slug) and the disclosure version, so a token issued for one
  # signer or one version proves nothing about any other. nil for a locale
  # this product does not speak — there is no such disclosure to vouch for.
  def locale_token(submitter, locale)
    locale = normalize_locale(locale)

    return if locale.nil?

    OpenSSL::HMAC.hexdigest('SHA256', locale_token_key, "#{submitter.slug}:#{VERSION}:#{locale}")
  end

  def locale_token_key
    Rails.application.key_generator.generate_key('esign_consent_locale', 32)
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

  # The locale this request renders the disclosure in — the one answer both
  # the modal (disclosure_html) and the consent record (record!) use, so the
  # text the signer was shown and the text the record fingerprints are the
  # same text by construction.
  def rendered_locale
    normalize_locale(I18n.locale) || I18n.default_locale.to_s
  end

  def normalize_locale(locale)
    base = locale.to_s.split('-').first.to_s.downcase

    base if locales.include?(base)
  end

  # The disclosure body (the HTML the modal renders) for a version and locale:
  # the live locale key for the current version, the archive scope for a
  # superseded one. nil when that pair was never published.
  #
  # `self_signing:` returns the variant a person signing their OWN document is
  # shown (self_signing_body) — the same words, minus the paragraphs that tell
  # them to write to themselves.
  def disclosure_text(version:, locale:, self_signing: false)
    locale = normalize_locale(locale)

    return if locale.nil? || !version.to_s.match?(VERSION_FORMAT)

    key = version == VERSION ? DISCLOSURE_KEY : "#{ARCHIVE_SCOPE}.#{version}"

    body = I18n.t(key, locale:, fallback: false, raise: true)

    self_signing ? self_signing_body(body, locale:) : body
  rescue I18n::MissingTranslationData
    nil
  end

  # "Sign it yourself": the sender and the signer are the same person, so
  # Submitters::ReplyTo.disclosure falls through to the account's own
  # administrator — themselves — and the disclosure ends up telling somebody
  # to email themselves for a paper copy or to withdraw. That is not a notice,
  # it is a joke at the signer's expense in a legal record.
  #
  # So the paragraphs that name an address to write to — "Who sent this",
  # "Withdrawing consent", "Paper copies" — come out, and one sentence saying
  # what is actually true goes in their place. They are picked out by the
  # `%{sender_email}` placeholder rather than by position, so this holds in
  # every locale without touching a word of the published bodies (whose bytes
  # the version digest pins). The rest of the disclosure is unchanged: what
  # you need, keeping a copy, and what we record all still apply.
  #
  # The substitution happens BEFORE the fingerprint is taken, so the event's
  # `disclosure_sha256` is of the text this signer really saw, and the audit
  # trail rebuilds the same text from the event's `self_signing` flag.
  def self_signing_body(body, locale:)
    paragraphs = body.to_s.split(%r{(?<=</p>)})
    replaced = false

    paragraphs.filter_map do |paragraph|
      next paragraph unless paragraph.include?(SENDER_EMAIL_PLACEHOLDER)
      next if replaced

      replaced = true

      "<p>#{I18n.t('esign_consent_disclosure_self_signing', locale:)}</p>"
    end.join
  end

  # Whether this signer is the person who sent the document — the "sign it
  # yourself" flow, where the sender's own login is the signer's email.
  def self_signing?(submitter)
    submission = submitter.submission
    sender = submission.created_by_user || submitter.template&.author

    sender.present? && submitter.email.present? && sender.email == submitter.email
  end

  # What a consent event's `disclosure_sha256` must equal for a later reader to
  # trust that the archived text is the one the signer saw. It fingerprints the
  # template, placeholders and all — see the module comment.
  def disclosure_sha256(version:, locale:, self_signing: false)
    text = disclosure_text(version:, locale:, self_signing:)

    Digest::SHA256.hexdigest(text) if text
  end

  # The disclosure the modal shows this signer: the current version's template
  # with the sender's name and address filled in. Both values are escaped
  # before they go into the HTML, so a sender cannot put markup in front of a
  # signer through their own account name.
  def disclosure_html(submitter, locale: nil)
    locale = normalize_locale(locale) || rendered_locale
    text = disclosure_text(version: VERSION, locale:, self_signing: self_signing?(submitter))

    return ActiveSupport::SafeBuffer.new if text.nil?

    filled = interpolate(text, sender_name: sender_name(submitter), sender_email: sender_email(submitter),
                               escape: true)

    # Safe by construction: the markup is our own locale template and the only
    # values put into it were escaped a line above.
    # rubocop:disable Rails/OutputSafety
    filled.html_safe
    # rubocop:enable Rails/OutputSafety
  end

  # The same disclosure as plain paragraphs, for a reader that cannot show
  # HTML (the audit-trail PDF).
  #
  # The tags come off the TEMPLATE and the sender's details go in afterwards,
  # never the other way round: an account really called `Acme <Legal> Ltd`
  # would otherwise have its own name eaten as a tag on the way through, and
  # the evidence would name a company that does not exist.
  def disclosure_paragraphs(text, sender_name:, sender_email:)
    plain_paragraphs(text).map do |paragraph|
      interpolate(paragraph, sender_name:, sender_email:)
    end
  end

  # Fills a disclosure template in. `escape:` for HTML display; plain-text
  # readers strip the markup first (disclosure_paragraphs) and escape nothing.
  def interpolate(text, sender_name:, sender_email:, escape: false)
    values = { sender_name:, sender_email:, product_name: Docuseal.product_name }
    values = values.transform_values { |value| ERB::Util.html_escape(value.to_s) } if escape

    I18n.interpolate(text, values)
  end

  def plain_paragraphs(text)
    text.to_s.split(%r{</p>}i).filter_map do |chunk|
      ActionController::Base.helpers.strip_tags(chunk).squish.presence
    end
  end

  # The name the disclosure gives as the sender: the account the document was
  # sent from, which is the party the signer is dealing with. An account can
  # be left unnamed, and a disclosure that says "sent by " and stops is worse
  # than useless in evidence — so the person who sent it, and finally the
  # product itself, stand in. Never blank.
  def sender_name(submitter)
    submission = submitter.submission
    sender = submission.created_by_user || submitter.template&.author

    submission.account.name.presence || sender&.full_name.presence || Docuseal.product_name
  end

  # The address the disclosure tells the signer to write to — "tell the sender"
  # has to name somewhere real. It is where a reply to this signer's
  # invitation email lands (Submitters::ReplyTo, whose header half the mailer
  # reads), and platform support only when that account has no reachable
  # address at all.
  def sender_email(submitter)
    Submitters::ReplyTo.disclosure(submitter) || Docuseal::SUPPORT_EMAIL
  end

  # What the page says it showed as the sender, as one fingerprint the form
  # sends back with the consent (see record!).
  def sender_digest(submitter)
    digest_of(sender_name(submitter), sender_email(submitter))
  end

  def digest_of(name, email)
    Digest::SHA256.hexdigest([name, email].join("\n"))
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

  private_class_method :consent_scope, :resolve_locale!, :verified_locale!, :locale_token_key, :self_signing_body
end
