# ESIGN/UETA consent — what signers agree to and what we keep

This document explains, in plain English, how EsignCenter collects a signer's
agreement to sign electronically, what is recorded, where it shows up, and the
one case where no agreement is collected.

## 1. What the signer sees

Every human signer sees a checkbox above the form's action buttons the first
time they open a document they have not yet agreed on:

> ☐ I agree to use electronic records and signatures. **Electronic Signature Disclosure**

- The **Next / Complete** buttons (including the header "Complete" button and
  the one-tap "Complete" for pre-filled forms) stay disabled until the box is
  ticked. Trying to complete another way (for example pressing Enter) shows
  "Please agree to use electronic records and signatures to continue." next to
  the box and moves focus to it.
- The **Electronic Signature Disclosure** link opens a short plain-English
  notice: consent to electronic records and signatures for this document, what
  hardware/software is needed, how to withdraw consent before completing (do
  not sign; tell the sender), how to ask for a paper copy (contact the sender),
  and that the agreement is recorded with date, time and IP address. The notice
  ends with its version and effective date.
- Once the box is ticked and the form sends its first request, the agreement is
  saved and the checkbox disappears for the rest of that signer's steps — and
  it does not appear again for that person, even if they reopen their link
  later. The one exception is delegation (below): the person the form is
  handed to starts with a fresh checkbox.
- The same checkbox appears in the template **form preview** (the dry run in
  the builder) so senders see exactly what signers will see. The preview never
  sends anything to the server.

This applies on every path a person can sign through: the emailed link, a
share link, an embedded signing session, a resubmitted form, a delegated
form, an email-2FA protected form, a form that invites the next party, and
"Sign it yourself".

**Delegation.** When a signer hands their form to someone else ("delegate to
another person"), the form keeps the same signer record but gets a new email
address and a new link. The new person is a different human, so their consent
is collected afresh: the checkbox is shown again, the form cannot be completed
until they tick it, and their agreement is recorded as its own event. The
first person's agreement is not erased — it stays in the event log, dated
before the hand-over — but it never counts for the person who signs after the
delegation.

## 2. What is recorded

Ticking the box creates **one** `esign_consent` event per person on the
signer (`submission_events`) — one for the original signer and, after a
delegation, one more for the person the form was handed to — stamped with:

- `version` — the disclosure version the signer saw (`v1` today),
- `locale` — the language the disclosure was shown in (`en`, `fr`, ... — the
  page sends back the locale it rendered; if it sends none, or one the
  product does not speak, the request's locale is recorded instead),
- `disclosure_sha256` — the SHA-256 fingerprint of the disclosure text in
  that version and language. The server computes it from its own locale data
  when the event is written; nothing about the text comes from the browser.
  `EsignConsent.disclosure_sha256(version:, locale:)` recomputes it, so a
  later reader can prove the archived text is the one the signer saw,
- `ip`, `ua` (browser user agent), `sid` (session) — the same tracking data
  every signing event carries — and `uid`, the user id, when the person who
  consented was signed in to the dashboard (the sender signing their own
  document, for example),
- `event_timestamp` — when the agreement was first sent to the server. Sending
  it again (later steps, retries) never creates a second event.

The agreement is recorded the moment it is first sent, even on a step save
that does not complete the form. A later completion request does not need to
repeat it. Only events newer than the signer's latest `delegate_form` event
count as that person's consent — the same rule the audit trail uses to decide
which events belong to the current holder of the form.

## 3. Where the server enforces it

All interactive signing ends in one place, `Submitters::SubmitValues`
(`lib/submitters/submit_values.rb`). Completing a form there without a
recorded consent event raises `EsignConsent::ConsentRequiredError`; the form
endpoints answer `422 { "error": "esign_consent_required" }`. On the signing
form itself (`PUT /s/:slug`) nothing is written: no completion time, no
completion job, no "completed" event. The invite request (`POST
/s/:slug/invite`, the form that invites the next party) may already have
created the invited signers before the refusal; the completion itself is
still refused, and the retry with consent is gated the same way. The form
shows the required message at the checkbox.

The consent logic lives in `lib/esign_consent.rb` (`EsignConsent`):
`consented?`, `record!` (idempotent per person — one event per delegation)
and `require!`; all three look only at consent events newer than the latest
delegation.

## 4. Where it shows

- **Audit trail PDF** — each signer's block shows
  "Consented to electronic signatures (v1, fr): <date and time>" — the
  version and the language the signer read the disclosure in — and the event
  log lists "**Consented to electronic signatures (v1)** by <signer>". The
  audit trail itself is written in the language of the last signer's
  `metadata.lang` when the sender set one, otherwise in the account's
  language.
- **Submission events page** in the dashboard — the same event line, with a
  shield-check icon.
- **API** — `GET /api/submitters/:id` and submission payloads include the
  `esign_consent` event with `data.version`, `data.locale` and
  `data.disclosure_sha256`.

## 5. The exemption: sender-attested completions

Some completions have no human signer at the keyboard: the sender attests the
values themselves through the API.

- `PUT /api/submitters/:id` with `completed: true`
- `POST /api/submissions` with a submitter `completed: true`
- `POST /api/signing_sessions` with a submitter `completed: true`

These are exempt by design. They create an `api_complete_form` event (never a
consent event) and are not consent-checked. The audit trail shows them as
completed via API, so a reader can tell the two kinds of completion apart.
The integrator's own application is responsible for that signer's consent;
the API reference and the embedding guides say so at the `completed` flag.

MCP "send documents" calls cannot mark a signer completed: every signer they
create is an ordinary human signer who goes through the gated form.

## 6. Changing the disclosure text — the version rule

The disclosure text is the locale key `esign_consent_disclosure_body_html`
(all 14 base locales in `config/locales/i18n.yml`). `v1` is the launch text;
nothing has shipped to production yet, so the text can still be edited under
`v1`.

**The rule:** bump the version the first time the text changes *after* any
production consent has been recorded under the current version. From then
on, every consent event points at a version whose text must stay
reproducible. When you bump:

1. Archive the superseded text of **every** base locale in
   `config/locales/esign_disclosures/<old-version>.yml` (for example
   `v1.yml`), shaped as

   ```yaml
   en:
     esign_disclosure_archive:
       v1: |-
         <p>By checking the box, ...</p>
   fr:
     esign_disclosure_archive:
       v1: |-
         <p>En cochant la case, ...</p>
   ```

   Rails loads that folder with the other locale files; the
   `esign_disclosure_archive` scope keeps an old text from ever shadowing
   the live key. That folder does not exist yet because nothing has shipped.
2. Update the text in every base locale.
3. Bump `EsignConsent::VERSION` (`v1` → `v2`) and `EsignConsent::EFFECTIVE_DATE`
   in `lib/esign_consent.rb`.

`EsignConsent.disclosure_text(version:, locale:)` then answers "what did a
signer who consented to `v1` in French read?" from inside the product — the
live key for the current version, the archive for older ones — and
`EsignConsent.disclosure_sha256` recomputes the fingerprint stored on each
event to prove the archived text is that one. Old events keep their old
version, locale and fingerprint. Signers who consented under an earlier
version are not asked again — a new version is a new text for new signers,
not a revocation.

The signing page sends back the version it displayed together with the
consent. A page that was opened before the bump and is only submitted
afterwards therefore cannot record the new version for a text the signer
never saw: the server refuses it, the page shows "The signing disclosure was
updated. Please reload the page and agree again." at the checkbox, and after
a reload the signer sees the new disclosure and a fresh checkbox. A request
that carries no version at all is refused the same way: only a consent that
names the current version is recorded.

## 7. Locale rule

Every consent string — the checkbox label, the disclosure link and title,
the disclosure body, the version label, the required message, the reload
message shown for a stale version, the audit-trail line and the event-log
line — exists as a real translation in all 14 base locales
(`en es it fr pt de pl uk cs he nl ar ko ja`; the regional variants inherit
them). `spec/golden/consent_spec.rb` fails if any locale is missing a key, if
a non-English locale is an English copy, or if an audit trail PDF generated in
any base locale would contain "translation missing".
