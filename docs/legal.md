# The Terms of Service and the Privacy Policy

Plain English: where the two legal documents live, how a rewrite is versioned
so an old agreement can still be produced, what is written down when somebody
agrees to them, and what a lawyer still has to decide.

The pages are `/terms` and `/privacy`. They are public — no login, no account
— and they are the two links on the sign-up form and the invitation form.

## 1. Where the words live

| Thing | File |
| --- | --- |
| The Terms of Service | `config/legal/terms.html.erb` |
| The Privacy Policy | `config/legal/privacy.html.erb` |
| Versions, rendering, digests, acceptance | `lib/legal_documents.rb` |
| Superseded texts | `config/legal/archive/<document>-<version>.html` |
| The pages | `app/controllers/legal_controller.rb`, `app/views/legal/` |
| One person's agreement | `legal_acceptances` (model `LegalAcceptance`) |

The two documents are **ERB templates, not views**. Every number in them —
the free plan's five completions, the $10 seat, the 14-day trial, the 90-day
deletion window, the storage caps — is interpolated from the constant the
product actually applies (`Quotas::Limits`, `StripeBilling::TRIAL_PERIOD_DAYS`,
`BillingSettingsController::PRICE_PER_SEAT_USD`, `Accounts::Deletion`,
`Accounts::Retention`, `BillingLifecycle`). A Terms of Service that repeats a
number by hand will eventually promise an allowance the code does not give,
and `spec/golden/legal_spec.rb` pins every one of them against its constant so
that cannot happen quietly.

**Rendering is deterministic.** Nothing time-dependent may go into either
template: the same version always renders the same bytes, wherever and
whenever. That is what makes the digest below mean anything.

**They are English only.** So are the marketing pages around them and the
platform notices the mailers send. A legal agreement translated by a machine
is a liability rather than a courtesy, and the text somebody accepted has to
be the one text we can produce again years later. The rest of the product is
translated into fourteen languages; these two documents are not.

## 2. The version rule

Each document carries a version (a date string), an effective date, **the
digest of the text that version publishes**, and the digest of every
superseded text still in the archive — all four in `LegalDocuments::DOCUMENTS`.

**Any wording change bumps both.** Not just a substantive one: the digest is
taken over the rendered bytes, so a corrected typo is a different document as
far as the record is concerned.

**And you cannot forget.** `spec/golden/legal_spec.rb` compares each live
render against the `sha256` written down beside its version, so the moment
anybody edits a word the suite goes red and stays red until the whole
procedure below has been carried out. The version is a date, so a **second
bump on the same day takes the next date** (a document bumped twice on
2026-09-05 becomes 2026-09-06, then 2026-09-07) — two different texts can
never share a version.

### How to bump one

1. **Archive the current text first.** Render the live document and write it
   verbatim to `config/legal/archive/<document>-<current version>.html`:

   ```
   docker compose -f docker-compose.dev.yml exec -T app \
     bundle exec rails runner \
     'File.write(LegalDocuments::ARCHIVE_DIR.join("terms-#{LegalDocuments.version(:terms)}.html"), LegalDocuments.html(:terms))'
   ```

   Then print that file's digest and record it in the document's `archived`
   hash in `lib/legal_documents.rb`, keyed by the version you just archived:

   ```
   shasum -a 256 config/legal/archive/privacy-2026-09-05.html
   ```

   Nothing is served out of the archive that does not still match the digest
   recorded here: `LegalDocuments.html` raises `ArchiveMismatchError` rather
   than hand back a text somebody may have edited since. An archive nobody
   checks is not a record, it is a file.
2. **Edit the template** (`config/legal/terms.html.erb` or
   `privacy.html.erb`).
3. **Bump `version` and `effective_on`** for that document in
   `lib/legal_documents.rb`, and **record the new `sha256`** — the digest of
   the text you have just written. Print it with:

   ```
   docker compose -f docker-compose.dev.yml exec -T app \
     bundle exec rails runner 'puts LegalDocuments.sha256(:privacy)'
   ```

   The version is a date in `YYYY-MM-DD` form; anything else is refused when
   the archive is read back.
4. **Email the administrators of every account — by hand, before the
   effective date.** This is a manual step. Nothing in the application sends
   it, there is no job and no scheduler entry; if you skip it, the Terms
   (section 26) and the Privacy Policy (section 12) both say we did it and we
   did not. Send it from the platform address, say what changed in one
   paragraph, link `/terms` and `/privacy`, and give the effective date.
   Keep a copy of what you sent with the archived text.
5. Run `spec/golden/legal_spec.rb`. It proves the live text hashes to the
   `sha256` you recorded, that every file in the real
   `config/legal/archive/` reads back at the digest recorded beside it, and
   therefore that an old acceptance row can still be resolved to the exact
   words behind it. If you skipped a step above, this is where it turns red.
6. Restart the application. The templates are read from disk and memoised per
   version (`LegalDocuments.render`), so a running process keeps serving the
   old text until it is restarted — which is also why the dev server needs a
   restart after any wording edit.

`LegalDocuments.html(:privacy, version: '2026-09-05')` answers with the
archived text for a superseded version, the live text for the current one,
`nil` for a version that was never published, and raises
`LegalDocuments::ArchiveMismatchError` for an archived file that no longer
matches its recorded digest.

The Privacy Policy has been through this once already: `2026-09-05` is
archived, `2026-09-06` is live. The change corrected two statements the code
did not support — what is kept when an account holder signs in (the IP
address of the current and previous sign-in, and nothing about the browser;
no separate record at all for a password change or a two-factor enrollment),
and what an audit trail says about a signer's email (the open and click
events stay off-plan, but the trail records on every plan that the address
was verified, because a click on the emailed link is what verifies it).

## 3. What is recorded when somebody agrees

Two rows — one for the Terms, one for the Privacy Policy — every time a login
is created. Each holds:

| Column | What it is |
| --- | --- |
| `user_id`, `account_id` | Who agreed, and the account they were in at the time |
| `document` | `terms` or `privacy` |
| `version` | The version they were shown |
| `sha256` | The digest of the exact rendered bytes of that version |
| `accepted_at` | When |
| `ip`, `user_agent` | What the request carried (blank when there was no request) |
| `source` | Which door: `signup_email`, `signup_google`, `signup_apple` or `invite` |

The version names the text and the digest proves it: with the archive, the
pair answers *"what exactly did this person agree to?"* years later. It is the
same pattern the signer's electronic-signature disclosure uses
(`lib/esign_consent.rb`, `docs/esign-consent.md`).

Rows are never updated. Agreeing to a newer version is a new row, so the table
reads as a history.

### The four doors

| Door | Where | Source |
| --- | --- | --- |
| Email + password sign-up | `Registrations.save_signup` | `signup_email` |
| Continue with Google | `Registrations.save_signup`, from `OmniauthCallbacksController#register` | `signup_google` |
| Continue with Apple | `Registrations.save_signup`, from `OmniauthCallbacksController#register` | `signup_apple` |
| Accepting a team invitation as a new person | `AccountInvites.accept!` | `invite` |

In all four the agreement is written **in the same transaction as the user**
— the user save at sign-up, the invitation's own row lock at acceptance — so
a person can never exist without one and an agreement can never exist without
a person. A failure to record it fails the sign-up.

**Accepting an invitation as a MOVE records nothing.** That person already has
a login and already agreed when they made it; the move changes which team they
are in, not what they agreed to. Their existing rows follow them into the new
team (`Accounts::MoveUser::MOVED_TABLES`), because the agreement belongs to the
person rather than to the company they were in when they made it.

### The version the person actually read

Every door sends back the version of each document the page it drew was
**displaying**, and refuses if that is no longer the current one — the same
rule `EsignConsent` applies to a signer's disclosure, for the same reason: an
acceptance is only worth having if we know which words were on the screen.

* the sign-up form and the invitation form carry hidden fields
  (`LegalDocuments.version_fields`, named `legal_version_terms` and
  `legal_version_privacy`);
* the "Continue with Google" button puts the same pair on the authorize
  request's query string, where OmniAuth hands it back as `omniauth.params` —
  exactly how the browser timezone travels;
* a request that sends **no** versions is stale too, so an old client cannot
  opt out of the check by staying silent.

A stale request is refused with `legal_documents_updated_please_review`
("Our terms were updated while you were reading…"), nothing is created, and
the person is shown the new text. The check runs at the door **and** inside
`record_acceptance!`, and at the door it runs *before* the per-network sign-up
budget is spent — a refusal that writes nothing must not use up an allowance
somebody else behind the same address is going to need.

`LegalDocuments.accepted_current?(user)` answers whether somebody has agreed to
the current version of both documents. Nothing gates on it today — it is there
so that whatever asks the question later (a re-acceptance prompt after a bump,
an operator report) asks it in one place.

### When an account is deleted

`legal_acceptances` is in `Accounts::Purge::INVENTORY` and goes with everything
else. It is deleted by **account and by user**, because the two sets are not
the same: somebody who joins another team leaves their row behind under the
account they agreed in, and brings none with them. See
`docs/account-deletion.md`.

## 4. For the lawyer

Both documents are **agent-drafted and have not been reviewed by counsel**.
Before launch, a lawyer needs to settle at least these:

1. **The operator's legal name and postal address.** Evan confirmed
   **EsignCenter LLC**, **1911 S National Ave STE 104, Springfield, MO 65802**
   on September 23, 2026. Both documents now identify that operator;
   `spec/golden/legal_spec.rb` refuses unresolved bracketed placeholders.
   The previous drafts remain archived at their original digests. Counsel
   still needs to review the documents. Future identity changes follow the
   same archive, version, effective-date and digest procedure above.
2. **Governing law and venue.** Currently the State of Missouri, USA
   (`LegalDocuments::GOVERNING_LAW_STATE`, Terms §20). Confirm the state, and
   decide whether an arbitration clause and a class-action waiver belong here.
   There is none today.
3. **The liability cap** — fees paid in the previous twelve months (Terms §16)
   — and the indemnity in §17.
4. **Consumer-protection and cancellation wording.** The Terms say there are
   no prorated refunds after the trial (§4). Some jurisdictions require more.
5. **What we deliberately do not claim.** Neither document says the product is
   "ESIGN compliant", "legally binding in all jurisdictions" or
   "court-admissible", and neither claims any certification (SOC 2, HIPAA or
   any privacy-regulation compliance). This is on purpose: we describe what
   the product does and record, and we do not tell a reader what a court would
   decide. `spec/golden/legal_spec.rb` fails if any of those phrases appears.
   Adding one is a decision for counsel, not for an engineer.
6. **No data processing addendum is offered** (Terms §13, Privacy §11), and no
   regional privacy-rights section (access, deletion, opt-out by jurisdiction)
   has been written. Both are deliberate gaps for counsel to fill.
7. **The signer's own consent flow** — the five questions about electronic
   records and signatures, the disclosure text and what is recorded — is a
   separate document, `docs/esign-consent.md`. Review it alongside these.
8. **The sub-processor list** in the Privacy Policy §5 must match the Trust
   page (`/trust`) and reality. Changing a vendor changes both, and bumps the
   Privacy Policy's version.
9. **Arbitration and a class-action waiver.** There is neither today. Whether
   to add them, and in what form, is a decision with real consequences for
   consumers and is not one an engineer should make.
10. **California's automatic-renewal law**, and the equivalents in other
    states. The paid plan converts a free trial into a charged subscription
    (Terms §4), which is exactly the shape those statutes regulate: what has
    to be disclosed before the card is taken, what the acknowledgment email
    must say, and how easy cancelling has to be.
11. **Whether Missouri law will actually carry the weight we put on it** —
    the liability cap (§16), the indemnity (§17) and the venue clause (§27),
    each tested against a consumer rather than a business.
12. **Which state privacy statutes apply to us**, and the question underneath
    them: is a SIGNER our data subject or the sender's? The product treats the
    sender as responsible for their signers (Terms §9, Privacy §8); a lawyer
    should confirm that is the right allocation and that our documents say so
    in the words those statutes expect.
13. **Whether "we do not sell or share" needs the statutory definitions.** We
    say it plainly (Terms §22). Some statutes define "sell" and "share" in
    ways that need the definitions quoted, or a specific link, to count.
14. **Who is bound by these Terms, and what assent each of them gives.**
    Account holders accept at sign-up and it is recorded (§3 above). Invited
    users accept when they join. Signers never see the Terms at all — they see
    the electronic-signature disclosure. Confirm that is right, and that the
    signer-facing sections say what they need to.
15. **What regulated data must be excluded**, and whether to say so. There is
    no exclusion today for data covered by financial, health or education
    privacy laws, and no statement about whether we will sign a business
    associate agreement. Both are gaps, and both belong to counsel.
16. **The S3 bucket's default encryption is a launch-gate check.** The Privacy
    Policy says files are stored with Amazon's server-side encryption
    (§10). `config/storage.yml` sets no encryption option, so the promise is
    kept by the bucket's own default. Confirm it is on for
    `S3_ATTACHMENTS_BUCKET` before launch, and again whenever the bucket
    changes — see `docs/render-deploy-checklist.md`.

## 5. The pages themselves

`LegalController` is public in the same way `VerifyController` is: no
authentication, no first-run setup redirect, no authorization check. Both
pages render in the marketing layout, declare themselves indexable
(`content_for(:indexable, true)` — see `app/views/shared/_meta.html.erb`), and
carry a plain-English summary above the document that says in as many words
that it is **not** the agreement.

The document itself sits in
`<article class="legal-document" data-legal-document data-legal-version
data-legal-sha256>`. Those attributes are the page telling you which text it
is showing and what its digest is, which is exactly what an acceptance row
holds — so a reader can check the two against each other without a database.

**There is no whitespace inside that `<article>` tag**, deliberately: its inner
HTML has to be the digest's input byte for byte, and a newline after the
opening tag would break the check for anybody trying to make it. Two
consequences for whoever edits the templates, both locked down by
`spec/golden/legal_spec.rb`: write characters rather than HTML entities
(`“`, not `&ldquo;` — a parser normalises the entity and the bytes
stop matching), and start any element that is followed by text on its own line
(`<li>` then `<strong>`, never `<li><strong>` — libxml2 re-indents the second
form).
The typography for that container is the `.legal-document` block in
`app/javascript/application.scss`; the documents themselves carry no CSS
classes at all, so a lawyer reads structure and nothing else.
