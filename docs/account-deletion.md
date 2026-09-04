# Deleting an account, and how long we keep one nobody uses

Plain English first, then the exact inventory of what is destroyed.

## The promise

Deleting your EsignCenter account is a **90-day decision**.

1. An administrator opens **Settings → Account**, presses **Delete my account**,
   reads what is about to happen and confirms with their password.
2. Straight away: the **subscription is cancelled** (you are not charged again)
   and the account becomes **read-only** — everyone can still sign in, read,
   download and export, but nothing new can be created or changed.
3. Everyone who administers the account gets an email with the exact date.
4. **On that date, 90 days later, everything is permanently destroyed.**
5. At any point before then, any administrator can sign in and press
   **Cancel deletion** — on the settings page, or on the banner that sits above
   every page. Nothing has been lost, so nothing has to be restored.

A reminder email goes out one week before the date.

Two things about the window are worth saying out loud:

* **Your email addresses stay reserved for you** until the purge. Nobody else
  can register them in the meantime. They are released the moment the purge
  runs, which is when the user rows are deleted.
* **Signing in does not cancel the deletion.** Only the button does.
* **Cancelling can occasionally say "try again in a few minutes."** The
  subscription is cancelled at Stripe the moment the deletion is asked for. If
  Stripe was unreachable at that moment, we will not lift the read-only state
  until we have confirmed the subscription really is cancelled — otherwise the
  account would come back with paid features nobody is being charged for.
  Nothing is changed when that happens: the deletion is still scheduled, and
  the button works normally once we have caught up (usually within minutes).

## Accounts nobody uses

An account nobody has signed in to for **a year** is deleted too, with warning
emails **60, 30 and 7 days** before. Those warnings go to *every* person in the
account, not just the administrators — the person who set it up may have left.
Each person gets their own copy, addressed only to them: nobody is shown who
else is in the account.

**Signing in once resets the whole clock.** The date is not stored anywhere: it
is computed every night from the last thing that happened (the most recent
sign-in, the account's own creation, or the day its subscription ended), so one
sign-in moves it a year into the future by itself.

**Nothing dormant is ever deleted unwarned.** A computed clock has no memory of
what anybody was told, so the 7-day letter leaves a mark on the row
(`accounts.dormant_warning_sent_at`, and the date it named in
`dormant_warning_for`) and an account is only destroyed once that mark is at
least a week old and the date it named has arrived. An account that was already
a year idle when this shipped — or that crossed its deadline while the
scheduler was down — therefore gets its final warning first and goes a week
later, rather than disappearing on the first sweep.

Two rules protect data that is not really abandoned:

* an account with **paid access** is never dormant, however quiet it is;
* an account that **used to pay** keeps everything for **a year after the
  subscription ended**, whatever the sign-in dates say.

**Downgrading is not deleting.** Dropping from the paid plan to the free one
never removes a document, a template or a person (D43). It only changes what
you can create next.

## What survives a purge, and why

| Survives | Why |
| --- | --- |
| `verified_documents` — the public /verify records | They hold a SHA-256 fingerprint, a date and a signer count. They name nobody, so they are not personal data — and if they went, every document the account ever signed would stop verifying for the people who hold it. Untouched, `account_id` included. |
| `account_subscriptions` — the money history | Stripe ids and states. No documents, no people. |
| `stripe_event_inboxes` — what Stripe told us and when | Kept, with `account_id` set to NULL **and the customer scrubbed out of the stored event**. What stays is the audit: the Stripe event id, its type, when Stripe sent it, what we did with it, and every id, amount, currency, price and status inside it. What goes is the person: email addresses, names, business names, phone numbers, street addresses, cities, postal codes, tax ids and free-typed descriptions are replaced with `[redacted]` wherever they appear in the event, however deeply nested. The event keeps its shape, so it still reads as an event — it just no longer says who it was about. |
| The `accounts` row itself | Renamed **"Deleted account"**, `archived_at` and `purged_at` stamped, uuid kept. Everything that still points at it (a verified document, a Stripe inbox row) points at *something* rather than nowhere. |

## The inventory

The purge does **not** rely on `account.destroy` and its cascade of
`dependent:` options. A cascade is invisible — a table added next year with a
foreign key and no association either blows the delete up or, worse, quietly
leaves rows behind. So `Accounts::Purge` (`lib/accounts/purge.rb`) walks this
explicit list, in this order, children before parents.

| Table | Action | Why |
| --- | --- | --- |
| ActiveStorage attachments + blobs | purged (files deleted) | Templates' documents; a submission's audit trail, combined, merged and preview PDFs; a submitter's documents, attachments and previews; generated documents; the account logo; each person's saved signature and initials — **and the page images that hang off all of those**. Every uploaded document is rendered into per-page PNGs, and those images are attached to the *attachment*, not to the template, so the walk goes down a level (and keeps going down until it finds nothing new) and takes the deepest ones first. Done **first** and through ActiveStorage, because the rows below are deleted with `delete_all` — anything still holding a blob at that point would leave the *file* in the bucket forever. **The work is grouped by file, not by attachment row**: cloning a template reuses the blob rather than re-uploading it, so two of this account's own attachments routinely name one file, and every row naming a file is deleted with it in one go. **A file another account is also attached to is kept**: only this account's attachment rows go, and the operator is told, because that is the one case where "everything was destroyed" is not quite true. **That question is asked again, under the file's own row lock, at the moment of deletion**, because somebody in a linked account can clone a template shared with them *while the purge is running* — and a clone reuses the file rather than copying it. Answering only once, at the start of the walk, meant such a clone could arrive a second too late to be seen and have its document deleted out from under it, permanently. Cloning takes the same lock, so the two serialise: the clone is either honoured and the file kept, or it comes after the file is gone and fails outright. **A file that will not delete stops the purge**: the account is *not* stamped as purged, the job retries, and the operator hears — a tombstone over a bucket that still holds their documents would be a lie. The order is deliberate: the stored object and its variants/previews go **first**, we verify the object is gone, and only then the attachment and blob rows. (ActiveStorage's own `Blob#purge` destroys the rows first, so a storage failure would orphan the file with no locator left to find it by.) |
| `completed_documents` | delete | Per-submitter document fingerprints. |
| `document_generation_events` | delete | Per-submitter generation log. |
| `submitter_versions` | delete | Delegation history. |
| `completed_submitters` | delete | The metering projection. |
| `submission_events` | delete | Opened, viewed, signed, consented. |
| `submitters` | delete | The people who signed. |
| `submissions` | delete | The documents. |
| `dynamic_document_versions`, `dynamic_documents` | delete | Generated documents hanging off templates. |
| `template_sharings`, `template_accesses` | delete | Who could see what. |
| `template_versions` | delete | Template history. |
| `templates` | delete | The templates. |
| `template_folders` | delete | Folders nest, so children are unhooked before parents. |
| `document_metadata` | delete | Per-blob checksums used for storage accounting. |
| `email_events`, `email_messages` | delete | Delivery history and stored copies. |
| `search_entries` | delete | The full-text index. Rebuildable. |
| `webhook_attempts`, `webhook_events`, `webhook_urls` | delete | Outbound integration and its delivery log. |
| `abuse_flags` | delete | Anti-abuse signals for this account. |
| `account_counters` | delete | Quota and dedupe counters. |
| `account_limit_overrides` | delete | Per-account limit overrides. |
| `account_accesses` | delete | Last-seen-in-account records. |
| `account_invites` | delete | Seats held for people who never arrived. |
| `account_linked_accounts` | delete (both sides) | A **testing child** is a corner of its parent, not an account of its own: it is purged *with* the parent, and its row is left as a tombstone exactly like the parent's (deleting it would leave `verified_documents.account_id` pointing at nothing, and `account_subscriptions` has a restricting foreign key). Every child is checked before any of them is touched — see the refusals below — so a family is emptied completely or not at all. |
| `account_moves` | delete | Who moved between accounts. |
| `encrypted_configs`, `account_configs` | delete | Settings, including any custom certificate material. |
| `provisioning_events` | delete | How the account was created. |
| `stripe_event_inboxes` | **scrub**, then **nullify** `account_id` | Keep the Stripe audit, remove the customer. Every verified webhook is stored byte for byte, and Stripe's bytes carry the customer's email, name, street address and postal code — so clearing `account_id` on its own de-identified nothing. The identity fields inside the stored event are redacted first; the ids, amounts, statuses and timestamps that make the row an audit are untouched. (The scrubbed bytes no longer match Stripe's signature. Nothing re-verifies them — only events the endpoint already verified are ever stored.) |
| `access_tokens`, `mcp_tokens`, `user_configs`, `encrypted_user_configs` | delete | Each person's keys, preferences and stored signature material. |
| `oauth_access_grants`, `oauth_access_tokens` | delete | Doorkeeper's tables (upstream DocuSeal's — the gem is not in this app, but the tables and their foreign keys are). Both **restrict** on `users`, so a single legacy row would blow the purge up half-way through. |
| `users` | **delete** | This is what releases the email addresses: the unique index is the only thing reserving them. Devise tokens go with the row. |
| `account_subscriptions` | **keep** | Money history (see above). |
| `verified_documents` | **untouched** | Public verification (see above). |
| `accounts` | **tombstone** | Renamed, stamped, kept. |

### Refusals

`Accounts::Purge.call` raises `Accounts::Purge::Refused` and alerts the
operator when:

* the account is **not a customer account** — internal and operator accounts
  are the platform itself, and purging an operator account would destroy the
  platform signing certificate;
* the account **still holds a live subscription**. An account that reached its
  purge date with a subscription still alive at Stripe means the cancellation
  never landed, and that is money that can still leave a customer's card.
  Cancel it at Stripe first. "Live" here is deliberately wider than "on the
  paid plan": a subscription Stripe has marked `unpaid` or `paused` shows up in
  this app as *suspended*, and one whose first payment never completed
  (`incomplete`) shows up as *cancelled* — none of them paid, all of them
  revivable from the customer portal and all of them able to charge a card. The
  purge refuses on any of them.
* a **testing child fails any of the same checks**: it is not a customer
  account, it holds a live subscription of its own, or the link table does not
  say plainly that it belongs to this parent and to nobody else (exactly one
  inbound link, of type `testing`, from this parent). A child rides in on its
  parent's decision, so it is checked as carefully as the parent is.

The purge also raises `Accounts::Purge::StorageFailure` — *not* a refusal, so
the job retries it — when a document's file could not be removed from storage.
`purged_at` is never stamped in that case.

**The decision is re-made immediately before anything is destroyed, and then
the account is claimed.** The nightly sweep decided minutes ago, and a retry may
be hours later; in between an administrator may have pressed "Cancel deletion",
or a dormant account's owner may simply have signed in. So `AccountPurgeJob`
takes a **short** lock, asks `Accounts::Retention.purge_eligible?` again, stamps
`accounts.purge_started_at`, and commits — then runs the purge **outside** any
transaction. (Holding the lock across the purge would mean a late failure
rolling back the row deletes while the files were already gone, and every
"Cancel deletion" queueing behind minutes of file deletion.)

The claim stamps `archived_at` as well, and that is the barrier: "archived" is
the state every door in this app already understands as *this account is gone*,
so from the moment of the claim the account is committed to deletion —

* **sign-in stops**, and so do the **signer write paths** (a signer part-way
  through a document cannot complete it into an account whose rows are being
  deleted), the **API and MCP tokens**, and the **quota chokepoint** every
  creation path shares;
* **cancelling is refused**, and says so ("This account is already being
  deleted and can no longer be restored") rather than reporting a success;
* a run that **fails leaves the claim in place**, so the retry resumes rather
  than re-deciding — a half-emptied account no longer looks eligible, and
  re-deciding would leave it half-emptied for ever;
* the purge **re-asserts its own refusals on entry**, so a Stripe webhook that
  puts the account back on a paid plan between the claim and the purge is still
  caught;
* **and the claim is released again** for every ending that is not
  "destroyed": a refusal (the account is not being deleted after all, so it
  must not go on looking as though it is); a storage failure whose retries have
  run out; and **any other failure** whose retries have run out — a database
  error, a deadlock, a bug. The last two also page the operator, because
  *half-purged and frozen for ever, silently* is not an outcome anybody chose.
  A claim left set would lock every user out of an account nobody is deleting.

**A Stripe subscription can never hand paid access back to a claimed account.**
`SubscriptionSync.apply!` still writes Stripe's facts — the ids, the status,
the period, so the money history stays readable — but forces the access state
to `cancelled` and alerts the operator: a live subscription on an account being
purged is a *money* problem, and only somebody at Stripe can stop the card
being charged.

**Nothing is entombed until it is actually empty.** The walk works from ids
collected at its start, so anything that lands during it — a webhook writing a
submitter, a job generating a document — would otherwise survive under a
tombstone claiming the account was emptied. So the family is swept a second
time and then every table of the inventory is counted; a count that is not zero
raises rather than stamping `purged_at`.

**Nobody can delete an account they are only visiting.** All three deletion
doors refuse while an operator is impersonating somebody: it would be the
operator's password or mailbox confirming the end of a customer's company. A
support agent who genuinely has to do this uses the rake tasks below.

Running the purge twice is a no-op: the second call sees `purged_at` and
answers `:already_purged`.

### Proving the walk was complete

`Accounts::Purge.orphans(account_id)` counts what is left in the four tables
that have **no foreign key** to `accounts` — `completed_submitters`,
`webhook_events`, `search_entries`, `submitters`. Nothing in the database would
have complained if the walk had missed one of those, so the spec and the rake
task ask instead. All four must be zero.

**The file count is deliberately asked a different way from the walk.** Before
anything is destroyed the purge writes down the ids of every template,
submission, submitter, generated document, person and the account itself, plus
every attachment it could reach from them. Afterwards it counts what still
hangs off those ids. That matters because the check used to reuse the walk's
own query, so it could only ever agree with it: when the walk did not know
about page images, neither did the count, and an account was entombed with the
customer's page images still in the bucket. Asking from the other end means a
hole *below* the starting list — a nested attachment the walk failed to reach —
ends the purge in a refusal instead of a false tombstone. It is not a second
opinion on the starting list itself: the count begins from the same seven owner
types as the walk, so a brand-new kind of attachment owner would have to be
added to both (there is none today — every `has_*_attached` in the app is one
of the seven).

**`webhook_attempts` is counted the same way, and for a sharper reason.** A
webhook delivery writes its attempt row *after* the outbound HTTP call comes
back — up to fifteen seconds later — and there is no foreign key tying an
attempt to its event. So a delivery that was in flight when the purge deleted
the events inserts its attempt against an id nothing points at any more, and no
query starting from the account could ever find it again: the old count read
zero and the account was entombed with a customer's webhook response body still
in the table. The purge now writes down the family's webhook event ids before
the walk, sweeps by them on the second pass, and counts against them — so a
straggler is either taken or the purge refuses. `completed_documents` is still
counted through its submitters, which the walk has already deleted by then; a
row written there mid-purge is not caught yet (recorded for Session 10).

## Operator commands

```
# Destroy one account now, skipping the rest of its 90-day window.
# Claims the barrier first (exactly as the nightly job does), releases it
# again if the purge refuses, and prints the orphan counts afterwards.
rake accounts:purge[123]

# Call off a scheduled deletion on the customer's behalf. Refuses out loud if
# the purge has already claimed the account — there is nothing whole left to
# restore.
rake accounts:cancel_deletion[123]

# Release a purge claim that is stuck: the account can be signed into and used
# again. If the purge had already begun deleting, the account is PART-EMPTIED —
# check before handing it back to the customer.
rake accounts:release_purge_claim[123]
```

`cancel_deletion` does **not** bring the subscription back — a Stripe
cancellation is not reversible from here. The account lands on the free plan
and can subscribe again from the billing page.

## Where the code lives

| Piece | File |
| --- | --- |
| Requesting and cancelling a deletion, and the Stripe cancel | `lib/accounts/deletion.rb` |
| The emailed confirmation code | `lib/accounts/deletion_codes.rb` |
| The purge inventory | `lib/accounts/purge.rb` |
| Dormant rules, warning schedule, purge scheduling | `lib/accounts/retention.rb` |
| Nightly sweep (`30 4 * * *`) | `config/schedule.yml` → `AccountRetentionJob` |
| One account's purge | `AccountPurgeJob` |
| The Stripe-is-down retry | `CancelDeletedSubscriptionJob` |
| The emails | `app/mailers/account_mailer.rb` |
| The screens | `app/views/accounts/_danger_zone.html.erb`, `_delete_account_form.html.erb`, `app/views/shared/_navbar_warning.html.erb` |
| The proofs | `spec/golden/lifecycle_downgrade_spec.rb` |

The subscription we cancel is stamped in Stripe metadata with
`esigncenter_cancelled = account-deletion` (and
`cancellation_details.comment = esigncenter:account-deletion` for whoever opens
the dashboard). That is deliberately a *third* value alongside the two the
duplicate-subscription logic uses, so a deletion can never be mistaken for a
duplicate and refunded: a customer who chooses to leave is not owed the month
they used back.
