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
the free plan's five completions, the $9.99 seat, the 14-day trial, the 90-day
deletion window — is interpolated from the constant the
product actually applies (`Quotas::Limits`, `StripeBilling::TRIAL_PERIOD_DAYS`,
`BillingSettingsController::PRICE_PER_SEAT_USD`, `Accounts::Deletion`,
`Accounts::Retention`, `BillingLifecycle`). A Terms of Service that repeats a
number by hand will eventually promise an allowance the code does not give,
and `spec/golden/legal_spec.rb` pins every one of them against its constant so
that cannot happen quietly.

**Two things are deliberately not stated as numbers.** Storage is described as
included, subject to fair use: the caps in `Quotas::Limits` still apply as a
safeguard, but no customer-facing text (these documents, the pricing page,
help, the usage page, the quota mail) quotes their size, and the legal,
marketing and help golden specs fail if a gigabyte figure comes back. Sales
tax is not collected at launch (D22/D22a, Stripe Tax off), so the Terms say
prices do not include it and that we will tell customers before adding it.

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

The Privacy Policy has been through this more than once: `2026-09-05`,
`2026-09-06`, `2026-09-23` and `2026-09-25` are archived, and `2026-09-26` is live. The
`2026-09-06` change corrected two statements the code did not support — what is kept when an account holder signs in (the IP
address of the current and previous sign-in, and nothing about the browser;
no separate record at all for a password change or a two-factor enrollment),
and what an audit trail says about a signer's email (the open and click
events stay off-plan, but the trail records on every plan that the address
was verified, because a click on the emailed link is what verifies it).

### The pre-launch copy and legal pass (September 25, 2026)

One bump of each document, covering every change in that review:

| Document | Archived | Now live | Effective | Live SHA-256 |
| --- | --- | --- | --- | --- |
| Terms | `2026-09-25` | `2026-09-26` | September 26, 2026 | `37d85b97ceb44190f407bc90492de034a4a4380a9a30d78c4e0eb24dcca15f6c` |
| Privacy | `2026-09-23` | `2026-09-25` | September 25, 2026 | `11340517403fd1760dcfb0290ae9be41332682da4cd62230bfced2a5396e9e1d` |

The Terms take the next date rather than `2026-09-25` because `2026-09-25`
was already published (the API usage tiers bump) and two texts may never
share a version. Both archived texts were rendered from the code as it stood
before the pass and checked against their recorded digests before being
written. What changed:

* **Support address** — `support@aceddev.com` (`Docuseal::SUPPORT_EMAIL`),
  wherever either document names it.
* **Sign in with Apple** — named beside Google in Terms §2 and §19 and in the
  Privacy Policy (the random password, the profile we receive, Apple's private
  relay address, and a row in the sub-processor table).
* **Storage** — included, subject to fair use; administrators are emailed
  before uploads pause; sending and signing are never stopped. No sizes.
* **Sales tax** — prices do not include it, we do not collect it today, and
  we will say so before adding it to an invoice.
* **Turnstile** — on the sign-up **and** support forms.
* **Sub-processor list** — both documents now link `/trust/subprocessors`.

Step 4 above (emailing every account's administrators before the effective
date) was not owed for this bump: no customer accounts existed yet. Counsel has not reviewed these texts (§4).

### Trial API packs are paid when added (September 25, 2026)

| Document | Archived | Now live | Effective | Live SHA-256 |
| --- | --- | --- | --- | --- |
| Terms | `2026-09-26` | `2026-09-27` | September 27, 2026 | `3b3c34867112071915151994dc8e59b1da85f8815b3807bdb316ae20d19c3542` |

The Terms said packs added during a trial were free until the trial ended,
which let a trial take any number of packs and cancel before paying. A trial
now pays for an added pack in full when it is added, exactly as an active
subscription does; the trial continues and the pack renews monthly once it
ends. The archived `2026-09-26` text was rendered from the prior code and
checked against its recorded digest. No customer accounts existed yet, so step 4 had no one to email.

### Sensitive information and Do Not Track (September 25, 2026)

| Document | Archived | Now live | Effective | Live SHA-256 |
| --- | --- | --- | --- | --- |
| Terms | `2026-09-27` | `2026-09-28` | September 28, 2026 | `4676747c166e9a64735d93a06a1581f74c9eeabf7455284ff14eb90c86a03a81` |
| Privacy | `2026-09-25` | `2026-09-26` | September 26, 2026 | `9182dbb72ea37b01cb3425ae1f570feb859ee8f1fc5c8f7f1738ea6c20f199be` |

From Evan's pre-launch terms review:

* **Terms §11, "Sensitive information"** (a subsection, so no section
  numbers moved). Health records, Social Security numbers and VA file numbers
  are allowed, because VA benefits claims carry all three and the sender is
  responsible for having the right to send them. Two things are refused:
  HIPAA-covered health information from a provider, a health plan or a
  business working for one (no BAA is signed), and full card numbers or
  security codes. `spec/golden/legal_spec.rb` bans HIPAA compliance claims
  and allows the word only in this exclusion.
* **Privacy §6, Do Not Track.** California's online privacy law requires a
  statement of how the site answers DNT. There is no cross-site tracking, so
  the answer is that there is nothing for the signal to turn off.
* Outside these documents, the same review removed "BAA on request" from the
  pricing page's Enterprise card. It contradicted the Trust page, and the
  vendor stack behind the product could not honor one.

Both archived texts were rendered from the code before the edit and checked
against their recorded digests. No customer accounts existed yet, so step 4 had no one to email.

### Copyright complaints under the DMCA (September 25, 2026)

| Document | Archived | Branch revision | Effective | Live SHA-256 |
| --- | --- | --- | --- | --- |
| Terms | `2026-09-28` | `2026-09-29` | September 29, 2026 | `aa90554ed203fa4f5ef7b193e4c815117ced43ae30dabc9e36cd06e66bfcc868` |

Evan asked for a DMCA policy in the Terms before launch. Terms §21 grew
from a notice recipe into the whole procedure the safe harbor in 17 U.S.C.
§ 512 expects (a subsection of §21, so no section numbers moved):

* **A designated agent** — `LegalDocuments::COPYRIGHT_AGENT_NAME` (a job
  title, "Copyright Agent", so a staff change does not force a re-filing) at
  the operator's postal address, reached at
  `LegalDocuments::COPYRIGHT_AGENT_EMAIL`. That is the support address until
  a dedicated inbox exists. Notices go to the agent, not to support.
* **The notice recipe** is unchanged, plus what happens to a notice that is
  incomplete and the warning that a knowingly false notice carries liability.
* **What we do with a valid notice** — remove or disable the material
  promptly, tell the uploader, and forward them the notice.
* **The counter-notice** — what the uploader sends to dispute a removal, that
  it is forwarded to the complainant, and that the material is restored
  between ten and fourteen business days later unless the complainant tells
  us they have gone to court.
* **Repeat infringers** lose their accounts, as before.

The archived `2026-09-28` text was rendered from the prior code and checked
against its recorded digest. This records the branch change; deployment still requires the applicable customer notice and acceptance review. What the words alone do not do is in §4 item 17: the agent
has to be registered with the Copyright Office, or the section is only a
promise to answer complaints.

### The copyright agent's telephone number (October 4, 2026)

| Document | Archived | Branch revision | Effective | Live SHA-256 |
| --- | --- | --- | --- | --- |
| Terms | `2026-09-29` | `2026-09-30` | September 30, 2026 | `7e048cf2029dfa34ff9853b294d84b864fb87120579d4f66220fcf30b1188775` |

Terms §21's agent block gains the telephone number the regulation requires
on the website (`LegalDocuments::COPYRIGHT_AGENT_PHONE`, given by Evan on
October 4, 2026). The owner decided to keep the support address as the
agent's email rather than open a separate inbox. The version takes the next
unused date after `2026-09-29`. The archived `2026-09-29` text was rendered
from the prior code and checked against its recorded digest. This records the branch change; deployment still requires the applicable customer notice and acceptance review.

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
   **EsignCenter LLC**, **1666 E Sunshine Street, Springfield, MO 65804**
   with the legal name reconfirmed October 3 and the no-suite address corrected
   October 6, 2026. Both documents identify that operator;
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
8. **The sub-processor list** in the Privacy Policy §5 must match the
   Sub-processors page (`/trust/subprocessors`) and reality. Changing a vendor
   changes both, and bumps the Privacy Policy's version;
   `spec/golden/marketing_spec.rb` fails if a company in the Privacy table is
   missing from the page.
9. **Arbitration and a class-action waiver.** There is neither today. Whether
   to add them, and in what form, is a decision with real consequences for
   consumers and is not one an engineer should make.
10. **California's automatic-renewal law**, and the equivalents in other
    states. The paid plan converts a free trial into a charged subscription
    (Terms §4), which is exactly the shape those statutes regulate: what has
    to be disclosed before the card is taken, what the acknowledgment email
    must say, and how easy cancelling has to be. What the product does today:
    Checkout requires a ticked box agreeing to the Terms and the monthly
    renewal (`consent_collection`, wording in
    `BillingSettingsController#renewal_consent_message`); a new subscription
    sends one acknowledgment email with the plan, price, first charge date and
    how to cancel (`BillingMailer#subscription_started`); cancelling is online
    in the Customer Portal. Counsel should still confirm the wording.
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
15. **What regulated data must be excluded.** Terms §11 ("Sensitive
    information") now excludes HIPAA-covered health information from covered
    entities and their business associates, and full card numbers, and says
    no BAA is signed. Health records in a VA benefits claim are deliberately
    allowed. Financial and education privacy laws are still not addressed;
    that gap belongs to counsel.
16. **The S3 bucket's default encryption is a launch-gate check.** The Privacy
    Policy says files are stored with Amazon's server-side encryption
    (§10). `config/storage.yml` sets no encryption option, so the promise is
    kept by the bucket's own default. Confirm it is on for
    `S3_ATTACHMENTS_BUCKET` before launch, and again whenever the bucket
    changes — see `docs/render-deploy-checklist.md`.

17. **The DMCA designated agent must be registered with the U.S. Copyright
    Office, or Terms §21 earns no safe harbor.** The filing is online only, at
    dmca.copyright.gov/osp, costs $6, and **expires after three years** unless
    renewed (amending or resubmitting restarts the clock; the Office emails
    reminders to whoever filed). It needs the operator's legal name and street
    address (no P.O. box), every alternate name the public might search under
    (EsignCenter, E-Sign Centre, the domain), the agent's name or title,
    mailing address, **telephone number** and email, and an administrative
    contact. What the Terms publish must match the filing exactly
    (`LegalDocuments::COPYRIGHT_AGENT_NAME`, `COPYRIGHT_AGENT_EMAIL`, the
    operator address), so file first and then correct the constants if they
    differ — that is a Terms bump. The agent's telephone number
    (`COPYRIGHT_AGENT_PHONE`) and email (the support address; the owner
    decided against a separate inbox on October 3, 2026) are both published
    in §21 now, so the filing can copy them. Counsel should read §21 with the
    rest.

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

### Unpublished release correction (October 3, 2026)

The prior candidate Terms and Privacy versions were `2026-10-03`. The current
postal address is 1666 E Sunshine Street, Springfield, MO 65804, with no suite,
as corrected by Evan on October 6. The Terms also distinguish the free plan trial from optional
API packs charged immediately; trial cancellation does not refund purchased
packs. Billing behavior is unchanged. Previous Terms `2026-09-28` and Privacy
`2026-09-26` are archived with their original hashes.

These are unpublished candidate documents, not legal clearance. Evan reconfirmed the exact
legal seller name EsignCenter LLC. The pack/refund treatment was subsequently approved on October 6; resolve the remaining retention/consent scope
issues before release. Set a prospective effective date and complete any
required customer notice/acceptance process before publishing. No notices
have been sent by this task; prior assertions that no customers existed are
historical and must not be reused as current evidence.

### Unpublished October 3 pricing revision

The owner changed seat and API-pack prices to $9.99/month and Business to
$49.99/month before this candidate was published. The current Terms template
derives these amounts from the billing constants. The unpublished 2026-10-03
Terms digest at that revision was `dde11d6f60bb12edc1636007c1187a73cf1325ca38f5a5e3346ef8e444b7739c`.
Published archived versions remain unchanged. This price instruction does not
resolve other outstanding legal-policy decisions. The separate trial-pack
timing/refund decision was made on October 6; no customer notice or production
publication has occurred.

### Unpublished release reconciliation (October 6, 2026)

The unpublished `2026-10-03` Terms candidate now includes the DMCA section
and designated-agent phone from the copyright-policy branch, with the approved
Sunshine Street address and current pricing. The `2026-09-29` archive is
preserved unchanged. The candidate version/date is not a claim of publication;
confirm a prospective effective date and required notice/acceptance before
deployment. No new policy decision or notice is made by this reconciliation.

The reconciled unpublished Terms digest before the pack-policy clarification was
`b201c5c92e21ddf43a7f69bab1b029c180f4c3c58645b0fe7197dc6c55b0a6d6`.
The Privacy digest and existing archived document bytes are unchanged.

### October 6 pack policy confirmation (unpublished)

The owner approved offering packs during trials: charge each new pack immediately,
with no automatic refund merely because the customer cancels. Current trial and
pack behavior already follows that rule. The candidate copy now distinguishes
that cancellation rule from refunds for duplicate or erroneous charges and
refunds required by law. Duplicate-charge recovery code remains unchanged.
The unpublished Terms digest after this clarification is
`705b4d70ce116702ab94283f5cf0efb2dbdb05aa3f5fbe903d2a1ddb6c4dbe74`. All published
archives remain byte-for-byte unchanged. The owner must still settle the actual
publication effective date and required notices/acceptance.

A distinct pay-as-you-go offering is absent from the implementation. The owner's
requirement to wait for a successful base-subscription payment is recorded in
`docs/billing.md`; a pack-only invoice cannot count as that payment. No new
product, price, or automatic overage charge has been added.


### October 6 address correction (unpublished)

Evan corrected both the business and DMCA mailing address to **1666 E Sunshine
Street, Springfield, MO 65804**, with no suite number. Both current document
versions are now `2026-10-06`. The exact previous `2026-10-03` candidate renders
are archived for reproducibility; they were unpublished drafts, not proof of
prior production terms or customer notice. All pre-existing archives remain
unchanged. Both current digests are refreshed for the corrected address/version.

The owner verified that the designated-agent registration is active, but the
directory still contains the older National Avenue address. The owner must amend
that government record to the approved no-suite Sunshine address. Keep the correct
current policy address; do not change archived snapshots to match the directory.
No government filing or provider-field change was performed by this code update.
The draft date is not evidence of publication: confirm the actual effective date
and required notice/acceptance before release.

Current unpublished `2026-10-06` digests:

- Terms: `1c2a45911eab0b4222686520be1c81c82097242964e9cfdecbbedb7e64f2af8b`
- Privacy: `03ef1952d6b5c0597ca87380c3f33fcd5e9f1da136d0eb438fd345af4da143a9`
