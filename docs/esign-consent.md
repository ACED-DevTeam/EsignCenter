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
- The **Electronic Signature Disclosure** link opens a plain-English notice
  covering everything 15 U.S.C. §7001(c) asks for: consent to electronic
  records and signatures for this document only, **who sent it** (the sending
  account's name and an email address that reaches them), that a copy will be
  available electronically, what hardware and software are needed, how to keep
  a copy, how to withdraw consent before completing (do not sign; tell the
  sender at that address — free, and the sender then has to arrange paper),
  how to ask for a paper copy and who may charge for it, how to change the
  email address documents are sent to, and what is recorded. The notice ends
  with its version and effective date.
- Next to the checkbox is a **View this document as a PDF** link. It opens the
  unsigned original — the same pages the form is showing — in a new tab, and
  **the checkbox stays disabled until it has been used once**, with the hint
  "Open the document as a PDF before you agree." underneath. That is the
  §7001(c) "confirm your device can display the record" step: the signer
  proves to themselves that they can open a PDF before agreeing to be sent
  one. The link is served by `GET /s/:slug/document.pdf`
  (`SubmitFormDocumentController`), keyed on the signing slug, behind the same
  email/link 2FA gate as the signing page and refusing on exactly the same
  terms — archived account, archived template or submission, expired, declined,
  or an enforced signing order that has not reached this signer yet. Page and
  door read one predicate (`Submitters::FormOpen`) so they cannot drift apart.
  A signer who has already completed is refused too, the way the page
  redirects one. It serves only what the page shows: the submission's schema
  with its conditions applied, in schema order, so a document a condition
  excludes is missing from the PDF too. A form with a single PDF is handed
  over as a short-lived signed storage link, so the file never passes through
  the app; several documents are merged on the way out. One slug may ask 20
  times an hour; beyond that it answers 429 with a readable line. (Like every
  rate limit here, that one fails **open** if Redis is unreachable — the limit
  stops applying until Redis is back and the failure is reported; see
  `RateLimit`.) Documents totalling more than 40 MB are not merged — the first
  one is served, which is the page the form opens on and enough to answer "can
  this device show a PDF?" — and when that happens the link on the form reads
  "View the first document as a PDF" instead, so the signer is not promised
  something they will not get. In the builder's form preview
  the same link answers off the template
  (`GET /templates/:id/form_document.pdf`), because the preview's signer
  record is never saved.
- **The "allow partial download" setting does not apply to this link.** That
  setting governs the "download what has been signed so far" button, which
  hands out a partly-completed document. This link serves the *unsigned
  original* the signer is already looking at, and consent cannot be given
  without it — switching it off here would leave those accounts' signers
  unable to agree at all.
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

- `version` — the disclosure version the signer saw (`v2` today),
- `locale` — the language the disclosure was shown in (`en`, `fr`, ... — the
  page sends back the locale it rendered; if it sends none, or one the
  product does not speak, the request's locale is recorded instead). The
  locale is browser-attested, like the `Accept-Language` header it comes
  from: the page sends it, and the fallback is the browser locale the
  signing page was rendered under — the server cannot prove which language
  the person actually read,
- `disclosure_sha256` — the SHA-256 fingerprint of the disclosure **template**
  in that version and language: the locale string with its `%{sender_name}`,
  `%{sender_email}` and `%{product_name}` placeholders still in it, not the
  filled-in words on screen. One fingerprint per version and language
  therefore answers "which disclosure was this?", and the parts that differ
  from sender to sender are the two fields below. The server computes it from
  its own locale data when the event is written; nothing about the text comes
  from the browser. `EsignConsent.disclosure_sha256(version:, locale:)`
  recomputes it, so a later reader can prove the archived text is the one the
  signer saw,
- `sender_name` — the sending account's name, as the disclosure showed it.
  A signed PDF must never read "sent by " and stop, so an unnamed account
  falls back to the name of the person who sent the document and then to the
  product name,
- `sender_email` — the address the disclosure told the signer to write to
  (withdrawing consent, asking for paper). It is where a reply to that
  signer's invitation email lands. One module answers for both —
  `Submitters::ReplyTo`, whose `header` half `SubmitterMailer` reads for the
  Reply-To header and whose `disclosure` half this field reads — so the
  address the disclosure gives can never be a mailbox the invitation did not
  use: the reply-to set on the signer, then the account's custom
  invitation-email reply-to, then the person who sent the document (skipped
  when that person is the signer, because replying to yourself reaches
  nobody), then the account's first active administrator, and platform
  support only if an account has nothing reachable at all.

  **The one case where the two halves differ.** A mail header is published to
  whoever receives it, so it stays conservative: a configured no-reply address
  or a self-signed document means **no Reply-To header at all**, and an
  account's own administrator mailbox is never put on an outgoing mail nobody
  asked to publish. The disclosure cannot stop there — a signer has to be able
  to withdraw consent and ask for paper — so in exactly those cases it keeps
  going and names the administrator. Wherever a reachable address is
  configured, which is the normal case, the two agree exactly; the header
  keeps the display name, the disclosure prints the bare address.

  Both fields are read off the server's own records, never sent by
  the browser. The form does send back one thing about them: a SHA-256 of the
  name and address **as it rendered them** (`esign_consent_sender_digest`).
  The server recomputes that fingerprint and refuses the consent as stale if
  it differs — an account renamed while the modal sat open cannot file one
  sender against a disclosure that named another. The signer reloads and
  agrees to the disclosure they can actually see,
- `pdf_opened` — `true` or `false`: whether the signer used the "View this
  document as a PDF" link before ticking the box. This is the **one** field on
  the event the browser asserts. A browser can post anything, so it is stored
  and printed as what it is: the audit trail says "The signer's browser
  reported opening the PDF", or "The signer did not open the PDF before
  agreeing" — never a bare claim of fact, and never silence,
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
  "Consented to electronic signatures (v2, fr): <date and time>" — the
  version and the language the signer read the disclosure in — followed by
  "The signer's browser reported opening the PDF", or "The signer did not open
  the PDF before agreeing". The event log lists "**Consented to electronic
  signatures (v2)** by <signer>". The audit trail itself is written in the
  language of the last signer's `metadata.lang` when the sender set one,
  otherwise in the account's language.

  A signer may have read the disclosure in a different language from the one
  the trail is written in, so the appendix below is set in the language that
  signer actually saw. Right-to-left is decided by that language, never by
  "does this string contain a Hebrew or Arabic character": an English
  disclosure that names an Arabic company is still an English sentence, so it
  is drawn as one, with only the interpolated names reordered — the same way
  the signer blocks have always handled a name.
- **The disclosure itself, at the end of the audit trail.** After the event
  log the trail carries one block per consent: "Electronic Records and
  Signatures Disclosure — Version v2 (fr), shown to <signer>", then the whole
  disclosure as plain paragraphs, in the language that signer read it in and
  with the sender's name and address filled in from the event. The evidence is
  self-contained: a reader years later does not need this product, or its
  locale files, to see what the person agreed to. An event recorded before the
  sender was named prints the template as it stands, above a line saying the
  sender's details were not recorded with that consent.
- **Submission events page** in the dashboard — the same event line, with a
  shield-check icon.
- **API** — `GET /api/submitters/:id` and submission payloads include the
  `esign_consent` event with `data.version`, `data.locale`,
  `data.disclosure_sha256`, `data.sender_name`, `data.sender_email` and
  `data.pdf_opened`.

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
(all 14 base locales in `config/locales/i18n.yml`).

**Versions so far**

| version | effective | state |
| --- | --- | --- |
| `v1` | 2 September 2026 | archived 5 September 2026 in `config/locales/esign_disclosures/v1.yml` (all 14 locales) |
| `v2` | 5 September 2026 | live — names the sender, links to the document as a PDF, and covers the §7001(c) points v1 left out |

Nothing had shipped to production under `v1`, but consents had been recorded
in the development stack, so the bump-and-archive rule below was followed
rather than editing `v1` in place. Those `v1` events still resolve: their
recorded `disclosure_sha256` matches
`EsignConsent.disclosure_sha256(version: 'v1', locale:)` computed from the
archive file.

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
   the live key. Take the text programmatically (`I18n.t(key, locale:,
   fallback: false)` in a runner) rather than by hand: the fingerprints are
   recomputed from what lands in the file, so a stray space is a real change.
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
them) — as do the "View this document as a PDF" link, the "open the PDF
first" hint, the "Document opened as a PDF" audit line, the appendix's
"shown to <signer>" heading and its missing-sender note.
`spec/golden/consent_spec.rb` fails if any locale is missing a key, if
a non-English locale is an English copy, or if an audit trail PDF generated in
any base locale would contain "translation missing".

## 8. For the lawyer hour

Open questions for counsel. They are product and policy decisions, not code
decisions, and the answers may change the text in §1 and the claims on the
trust page.

1. Does §7001(c) consumer consent apply to our document types at all, and may
   senders switch it off for B2B or substitute their own text?
2. Is "withdraw before you complete, by not signing" an adequate withdrawal
   right, or is an affirmative withdraw control and record required?
3. Is a click-through modal sufficient prior provision of the disclosure, and
   must we record that it was opened?
4. Does the platform or the sender own the paper-copy and fee obligations, and
   must the Terms make the sender responsible?
5. Which marketing claims are earned — review the trust page's claim register
   sentence by sentence.
