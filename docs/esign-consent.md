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
  it never appears again for that signer, even if they reopen their link later.
- The same checkbox appears in the template **form preview** (the dry run in
  the builder) so senders see exactly what signers will see. The preview never
  sends anything to the server.

This applies on every path a person can sign through: the emailed link, a
share link, an embedded signing session, a resubmitted form, an email-2FA
protected form, a form that invites the next party, and "Sign it yourself".

## 2. What is recorded

Ticking the box creates **one** `esign_consent` event on the signer
(`submission_events`), stamped with:

- `version` — the disclosure version the signer saw (`v1` today),
- `ip`, `ua` (browser user agent), `sid` (session) — the same tracking data
  every signing event carries,
- `event_timestamp` — when the agreement was first sent to the server. Sending
  it again (later steps, retries) never creates a second event.

The agreement is recorded the moment it is first sent, even on a step save
that does not complete the form. A later completion request does not need to
repeat it.

## 3. Where the server enforces it

All interactive signing ends in one place, `Submitters::SubmitValues`
(`lib/submitters/submit_values.rb`). Completing a form there without a
recorded consent event raises `EsignConsent::ConsentRequiredError`; the form
endpoints answer `422 { "error": "esign_consent_required" }` and nothing is
written: no completion time, no completion job, no "completed" event. The
form shows the required message at the checkbox.

The consent logic lives in `lib/esign_consent.rb` (`EsignConsent`):
`consented?`, `record!` (idempotent) and `require!`.

## 4. Where it shows

- **Audit trail PDF** — each signer's block shows
  "Consented to electronic signatures (v1): <date and time>" (in the
  account's language), and the event log lists
  "**Consented to electronic signatures (v1)** by <signer>".
- **Submission events page** in the dashboard — the same event line.
- **API** — `GET /api/submitters/:id` and submission payloads include the
  `esign_consent` event with `data.version`.

## 5. The exemption: sender-attested completions

Some completions have no human signer at the keyboard: the sender attests the
values themselves through the API.

- `PUT /api/submitters/:id` with `completed: true`
- `POST /api/submissions` with a submitter `completed: true`
- `POST /api/signing_sessions` with a submitter `completed: true`
- MCP "send" calls with completed values

These are exempt by design. They create an `api_complete_form` event (never a
consent event) and are not consent-checked. The audit trail shows them as
completed via API, so a reader can tell the two kinds of completion apart.

## 6. Changing the disclosure text — bump the version

The disclosure text is the locale key `esign_consent_disclosure_body_html`
(all 14 base locales in `config/locales/i18n.yml`). Whenever its meaning
changes:

1. Update the text in every base locale.
2. Bump `EsignConsent::VERSION` (`v1` → `v2`) and `EsignConsent::EFFECTIVE_DATE`
   in `lib/esign_consent.rb`.

Old events keep their old version, so the audit trail always says which text
a signer agreed to. Signers who consented under an earlier version are not
asked again — a new version is a new text for new signers, not a revocation.

The signing page sends back the version it displayed together with the
consent. A page that was opened before the bump and is only submitted
afterwards therefore cannot record the new version for a text the signer
never saw: the server refuses it, the page shows "The signing disclosure was
updated. Please reload the page and agree again." at the checkbox, and after
a reload the signer sees the new disclosure and a fresh checkbox. A request
that carries no version at all is refused the same way: only a consent that
names the current version is recorded.

## 7. Locale rule

Every consent string exists as a real translation in all 14 base locales
(`en es it fr pt de pl uk cs he nl ar ko ja`; the regional variants inherit
them). `spec/golden/consent_spec.rb` fails if any locale is missing a key, if
a non-English locale is an English copy, or if an audit trail PDF generated in
any base locale would contain "translation missing".
