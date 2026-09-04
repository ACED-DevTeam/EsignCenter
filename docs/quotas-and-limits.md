# Quotas and limits — what an account may do, and what happens at the edge

Plain-English reference for every cap, throttle and abuse policy in
EsignCenter. The numbers live in one place in the code, `lib/quotas/limits.rb`
(`Quotas::Limits`); the engine that applies them is `lib/quotas.rb`; the
sending pause is `lib/sending_pause.rb`; storage is `lib/quotas/storage.rb`.

## 1. The rules in one table

| Limit | Value | Who it applies to | What happens at the limit |
|---|---|---|---|
| Documents completed per month | 5 | Free | New documents cannot be sent or started until the month resets. Documents already sent can still be signed. |
| Completion warning | at 4 of 5 | Free | One email per month to the account's admins. |
| Documents sent per month | 15 | Free | The 16th send is refused; a batch that would cross the line is refused whole. |
| Documents waiting for signatures | 10 | Free | The 11th open document is refused until one completes, is declined, expires or is deleted. |
| Seats | 1 | Free | Inviting (or reactivating) a second user is refused. |
| Storage | 1 GB | Free | Uploads by account users are refused; sending and signing keep working (section 5). |
| Storage | 10 GB per seat | Paid | Same — uploads only, never sending. |
| Fair-use review | 500 completions per seat per month | Paid | Nothing is blocked. An email at 80%, a review flag for the operator at 100%. |
| Send velocity | 200 sends per seat per day | Paid | Nothing is blocked; a warn-flag for the operator. |
| Open documents | 50 per seat | Paid | Nothing is blocked; a warn-flag for the operator. |
| Sign-ups per IP | 5 per hour, 20 per day | Registration | Further sign-ups from that network are refused for the window. Counts sign-ups, not attempts. |
| Sign-up attempts per IP | 30 per hour | Registration | Further tries from that network are refused with *Too many sign-ups from this network* before the Cloudflare check is even asked. Counts every try, however it ends. |
| Google sign-in round-trips per IP | 60 per hour | Registration | Only the one request that makes us call Google counts: the return trip from Google carrying the code this browser started with. Past 60 that return trip is refused (429, empty body) in front of Google, so no token exchange is made. Every other `/auth/...` request is answered normally and counts for nothing, so a page elsewhere on the web cannot spend a visitor's allowance for them. |
| Spam complaints | 1 | Any customer account | Sending pauses until the operator reviews (section 3). |
| Hard bounces | 20% of the last 20 sends, once 10 have gone out | Any customer account | Sending pauses until the operator reviews (section 3). |

**Who is exempt:** internal and operator accounts, from every row. Their
test-mode submissions never meter either — test-mode belongs to internal
accounts only, so nothing a customer does is "test".

**Paid accounts are never auto-blocked by a quota** (D42). The only thing that
stops a paid account from sending is the complaint/bounce policy, which is
about abuse, not usage.

### What "a document completed" means (D41)

A document counts the first time **any** signer completes it. A two-signer
document counts once, when the first of them finishes; the second signer's
completion adds nothing. Corrections, resends and re-completions of the same
signer add nothing. A document that is declined or expires with no signatures
counts nothing. (In the data: the `completed_submitters` row with `is_first`,
counted by `completed_at` in the UTC month.)

### Correcting a signed document and sending it again (D73)

Sometimes a document is signed and only then does someone spot a mistake. The
fix is to correct it and send the same document out again. Two doors do that,
and they are the two that carry the correction forward:

- **Resubmit on the dashboard** — the owner corrects a document they sent;
- **Resubmit on a signer's completed page**, reached from the link that was
  sent to that signer.

That corrected copy is a **new document to sign**, so it costs a send; but it
is the *same* document, so when it is signed it does **not** cost a second
completion, however many rounds of corrections it takes.

It is the whole **family** that is counted once, not just a chain of
ancestors: two corrections of the same document are counted once between
them, and if the original was never signed and only a corrected copy is, that
still counts exactly one completion — the first time anyone finishes any copy
of it.

Two edges worth knowing:

- The **Resubmit button on a shared link's completed page** starts a *fresh*
  document rather than a correction. A shared link cannot safely work out
  which of its signers the page belongs to, so that copy has no family and
  counts as a new document when it is signed.
- Permanently deleting the original does **not** re-open the family: the
  family is remembered as a number that survives the document it names, so a
  corrected copy signed afterwards still counts nothing extra.

What still counts every time is the **send**. Each copy is a new document
going out, so each one uses one of the month's sends (15 on the free plan),
and that is the limit that bounds this: nobody can loop corrected copies past
the completion cap without running out of sends first.

Because a correction cannot add a completion, the completion cap does not
stand in its way either (D74): **correcting a signed document never uses a
completion and is allowed even when you've reached the monthly limit; it
still counts as a send.** So a free account that has used all five
completions can still fix and re-send a document somebody already signed —
which is exactly when a mistake is usually spotted — while the sends cap, the
open-documents cap, a sending pause and a billing suspension all still apply.
A correction of a document whose family has never been completed is not this
case: nothing has been counted for it yet, so it is an ordinary new document
and the completion cap refuses it like any other.

(In the data: `submissions.lineage_root_id` names the document the family
started from — set on every copy, with no foreign key so it outlives a
deletion — and `submissions.resubmitted_from_id` points at the copy this one
was corrected from. `Submissions::Lineage` reads the family when a completion
is recorded, under a per-family lock so two copies finishing at the same
moment still count once.)

### What "a document sent" means (D58)

Every submission created, on any path — the recipients form, the API, MCP, a
signing session, a share link, "sign it yourself", a Resubmit — is a send the
moment it is created. Deleting or archiving a document never gives the send
back: the counter only goes up (`account_counters`, key
`submissions_created`).

### What "waiting for signatures" means

Not archived, not expired, nobody has declined, and at least one signer has
neither completed nor declined — and the template it came from is not
archived. Counted live from the documents themselves.

### Months and resets

All monthly limits use the UTC calendar month. They reset at 00:00 UTC on the
first of the next month, by themselves: nothing is stored that says "this
account is capped", so there is no job to run and nothing to reset. A share
link that was closed by a monthly cap (completions or sends) on the 31st simply
works again on the 1st. A link closed because ten documents are still waiting
for signatures reopens as soon as one of them completes, is declined, expires
or is deleted; a sending pause is lifted only by the operator.

### Children roll up to their parent

An account that is another account's testing child or linked "team" account
is billed through the parent (`Plans.billing_account`): the parent's plan
applies and the child's documents count toward the parent's limits.

## 2. Where the caps are enforced

Every path that creates a document to sign makes the same check, inside the
same lock, before anything is saved:

1. Recipients form — emails typed into the box.
2. Recipients form — recipients added one by one (also the API's
   `POST /api/submissions`, MCP `send_documents`, and embedded signing
   sessions, which all go through the same service).
3. The share link (`/d/...`), "sign it yourself", and a signer's Resubmit.
4. The share link's email-verification code (no code is sent for a form that
   cannot be started).
5. The dashboard Resubmit.
6. The recipients form's own controller (the alert the sender sees).
7. The API, MCP and signing-session doors (a `422` with the reason).

A refusal creates nothing and queues no job. The sender sees the reason in
their own language; a signer opening a paused share link sees "This form is
not accepting new responses right now" and is asked to contact whoever shared
it. The owner is emailed once per month that a signer was turned away.

The lock (`Quotas.with_creation_lock`) is a database advisory lock per
billing account: two people sending at the same moment from one account are
served one after the other, so "14 of 15" can never become 16.

### The other throttles (Sessions 2–4)

These are speed limits rather than monthly caps, kept in Redis:

| Throttle | Value |
|---|---|
| Public verify page | 10 per minute and 100 per hour per visitor IP |
| Word document conversion | 30 per hour per account |
| API template / signing-session creation | 300 per minute |
| Resend an invitation / reminder / signer copy | one per 10 h / 10 h / 4 h |
| "Send me a copy" of documents | 2 per 5 minutes |
| Share-link email-verification code | 2 per 45 seconds per IP, and 100 per hour per account |

**One code, one inbox.** The share link's verification code goes to exactly
one properly-formed address. Anything else typed into that box — two
addresses, a list, a name in angle brackets, a stray line break — is answered
with *Email is invalid* and nothing is sent. Otherwise one visitor could mail
a whole list of strangers from the platform's own sending account, and the
account's hourly ceiling above is what stops anyone doing it one address at a
time.

**Fail-open rule.** The Redis throttles above fail open by design: if Redis
is unreachable the limit is off until it is back, and the outage is reported.
Availability wins for a speed limit. The monthly caps and the sending pause
never depend on Redis — they read Postgres, so they hold even when Redis is
down.

## 3. The sending pause (abuse policy)

Applies to every customer account, free or paid. Two triggers:

- **One spam complaint** — a recipient marks an email from the account as
  spam.
- **Bounce rate** — among the last 20 emails sent, at least 10 have gone out
  and 20% or more hard-bounced (the address does not exist).

When it fires: the account's `sending_paused_at` is set, a flag is recorded
for the operator, the account's admins get an email explaining why, what still
works (signers on documents already sent can still complete; downloads work)
and that the operator will review, and the operator is alerted. From then on
every creation path refuses with "Sending is paused for this account while we
review a delivery problem" until the operator lifts it:

```
bundle exec rake "operator:resume_sending[ACCOUNT_ID]"
```

Resuming clears the pause and resolves the open complaint/bounce flags.
Session 8's Postmark webhook is what calls the policy (`SendingPause.evaluate!`)
after it records a delivery event; nothing calls it before then.

## 4. Overriding a limit for one account

The operator can raise or lower any cap for one account without touching the
code — the override wins over the plan default, field by field:

```
bundle exec rake "operator:limits[ACCOUNT_ID,completions_per_month,50]"
bundle exec rake "operator:limits[ACCOUNT_ID,sends_per_month,100]"
bundle exec rake "operator:limits[ACCOUNT_ID,in_flight,40]"
bundle exec rake "operator:limits[ACCOUNT_ID,seats,3]"
bundle exec rake "operator:limits[ACCOUNT_ID,storage_bytes,5000000000]"
bundle exec rake "operator:limits[ACCOUNT_ID,completions_per_month,]"   # clear: back to the plan default
```

Overrides live in `account_limit_overrides` (one row per account). The
Session 8 console edits the same row; no customer-facing page writes it.
Overrides change caps only — they never turn the paid fair-use review into a
block. Internal and operator accounts have no caps to override: the task
refuses them, and the engine ignores an override row on one if it ever
existed.

Warn-flags for the operator (`abuse_flags`): `fair_use_review`,
`send_velocity`, `in_flight`, `complaint`, `bounce_rate`, and Phase D's
`document_report`. One per account, kind and period where a period applies;
Session 8's abuse queue lists them.

## 5. Storage

Storage is the one cap that applies to paid accounts too, and the one that
never touches sending or signing: a full account can still send every
document it already has, and every signer can still complete.

**What counts.** Every file the billing account (and its linked children)
holds, each counted once: uploaded template documents, the signed PDFs and
audit trails of its submissions, files and signatures its signers uploaded,
the preview images of all of those, the account logo, and its users' saved
signatures. The number on the usage page is the real total — there is no
"only documents count" small print. It is read live from the file table in
one query (`Quotas::Storage.bytes_used`).

**The caps.** Free: 1 GB. Paid: 10 GB per seat (2 seats = 20 GB). Internal
and operator accounts: no cap. The operator can change one account's cap
with `rake "operator:limits[ACCOUNT_ID,storage_bytes,BYTES]"` (section 4).

**Which uploads are refused when the account is full.** Only uploads made
by the account's own users, and only when the file would take the account
past its cap (the size of what is being uploaded is checked before anything
is stored, so a refused upload leaves nothing behind):

- the dashboard "upload" (files, URLs and Word documents alike),
- "add document" in the template builder and in the embedded builder,
- `POST /api/templates`, MCP `create_template`, signing sessions and builder
  sessions that carry documents,
- clone-and-replace and any other path that replaces a template's files,
- the branding logo.

All of these store their files through one place
(`Templates::CreateAttachments.call`, the logo aside), which asks the cap
once, after zip extraction and before the first blob is written. The person
uploading sees "Your storage is full (X of Y). Delete documents you no longer
need or upgrade for more space." — as a page alert on the dashboard, an
inline error in the builder, and a `422` with the same sentence on the API.

**Never refused, by design.** A signer's field uploads and drawn signatures,
the signed PDFs and audit trails the platform generates when a document
completes, preview images, Word-conversion output, and users' saved
signatures and initials. Storage is a brake on new uploads, never a reason a
document fails to complete.

**The 80% warning.** When an upload leaves the account at 80% or more of its
cap, the account's admins get one email per month ("Your EsignCenter storage
is almost full") saying what counts and how to free space. Like the other
quota mail, the once-per-month guard is a durable counter, not a memory.

**Freeing space.** Delete templates and documents you no longer need. There
are two steps, and only the second one frees space: the ordinary "delete"
moves the item to the archive, where its files still exist and still count;
"delete permanently" on the archived list really removes it, and the total
goes down at once — the uploaded documents, the signed PDFs, the audit trail
and every preview image that hung off them. Deleting a template permanently
takes its documents to sign with it.

## 6. The usage page

Every account has `/settings/usage` ("Usage" in the settings menu, next to
Account). It shows, live:

- the plan (Free / Paid with the seat count / Internal), and a red banner
  when sending is paused, with the support address;
- five meters — documents completed this month, documents sent this month,
  documents awaiting signatures, storage used, seats used — each as "x of N"
  with a bar. A paid account sees plain numbers for the first three (with
  the fair-use level noted) and its real caps for storage and seats;
- when the monthly limits reset: the first of next month at 00:00 UTC, and
  the same moment in the account's own timezone;
- for a free account, the upgrade call-to-action.

Over the cap is shown as it is — "7 of 5" with a full bar and a "Limit
reached" badge, never rounded down to the cap — so what the page says always
matches why a send was refused. (A free account can pass 5 completions when
documents it sent earlier keep completing: completion is never blocked.)

Internal accounts see "Internal account — no limits apply" and their raw
numbers. A testing or linked child sees its parent's numbers, because that
is the account being metered.
