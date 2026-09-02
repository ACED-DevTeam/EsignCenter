# Public document verification (/verify)

`/verify` is a public page — no login, no account — where anyone holding a PDF
can check whether EsignCenter produced it. It exists so a third party (a bank,
a landlord, a court clerk) can confirm a document is genuine without being
given access to anything else.

## 1. What the page reveals

For a genuine, unmodified file the page says exactly one thing:

> This document was completed through EsignCenter on 2 September 2026 by 2 signers.

That is the whole answer: the **day** the signing finished (in UTC, no time of
day) and **how many people** had completed the document by then.

## 2. What it never reveals

- who signed — no names, email addresses or phone numbers
- what was signed — nothing from the document's contents
- the certificate details, the signing reason text or the time of day
- whether a *particular person* signed anything

The page is deliberately dumb: it cannot be used to look people up, and it
does not tell an attacker anything they could not already learn by opening the
PDF in a reader.

## 3. The three answers

| Result | Meaning |
| --- | --- |
| **Verified** | The file's digital signature is ours and its bytes match a document we recorded at signing time. Shows the day and the signer count. |
| **Not on record** | The file carries an EsignCenter signature, but its bytes match no recorded document. Either it was changed after signing (even one added byte counts), or it was produced before verification records existed (see section 6). |
| **Not verified** | The file has no EsignCenter signature at all — it was not completed here, or it was altered so badly the signature no longer checks out. |

A PDF with a byte appended after signing lands in **Not on record**: the
original signed byte range still validates, so the file is recognisably ours,
but nothing in our records matches the altered bytes.

## 4. How the records are written

Every time EsignCenter signs a PDF it stores a `verified_documents` row with
the SHA-256 fingerprint of the exact bytes it uploaded, the moment, the number
of signers who had completed the submission, and the account and submission
ids for provenance. Three artefacts are recorded:

- the per-signer signed document (`kind: document`) — the file a signer downloads
- the combined PDF (`kind: combined`)
- the audit trail (`kind: audit_trail`)

The write happens inside the signing job and is never rescued: if the database
refuses the row, the job fails and Sidekiq retries it, because a signed PDF
without a record would answer "not on record" forever.

A migration backfilled the fingerprints of documents signed before this page
existed (they were already stored, base64-encoded, in `completed_documents`).

## 5. Why the records outlive deletion

The row has **no foreign keys and no associations**. Deleting a submission,
purging an account, or running any future retention job leaves it untouched,
so a document signed years ago still verifies after the sender's account is
long gone. The row holds no identities, which is what makes keeping it forever
acceptable.

Session 7's deletion inventory must list `verified_documents` as **KEEP**.

## 6. Limits

- One PDF per request, up to **25 MB**. A larger file is refused before it
  is read into memory or parsed as a PDF: first from the request's declared
  size (with a 1 MB allowance for the upload envelope, so a valid 25 MB file
  is not turned away), then from the file's own size.
- The file must actually be a PDF (the bytes are sniffed, the extension is
  ignored). Anything else, or a PDF that cannot be parsed, is refused.
- **10 checks per minute** and **100 per hour** per IP address. The eleventh
  attempt gets a friendly "wait a minute" message with a 429 status.

## 6a. What counts as "our" signature

A signature is ours only when it was made with the platform certificate
(current **or retired** — see below), or with an internal or operator
account's own certificate. Extra root certificates listed in the
`TRUSTED_CERTS` environment variable help check a signature's chain but never
make a signature count as EsignCenter's.

- **Rotating the platform certificate keeps old documents verifying.**
  `rake operator:platform_cert:rotate` moves the old chain to a retired list
  that the page trusts forever; nothing is deleted. Documents signed under a
  retired certificate still answer **Verified** (docs/operations.md 8.3).
- **The page never creates the platform certificate.** If it does not exist
  yet, every upload answers "not verified" until the seed or the first
  signing creates it — an anonymous visitor cannot trigger that.
- **One unreadable certificate row does not break the page.** A corrupt
  uploaded certificate on an internal account is reported to Sentry and
  skipped; every other signature still verifies.
- **Launch-gate check (pre-Session-4 history):** Session 1 turned every
  pre-existing account into an internal one and copied one certificate row to
  all of them, so no production document is expected to carry a signature
  from a *customer-kind* account's own certificate. If one is ever found (the
  page says "not verified" for a document that should verify), that
  account's certificate row still exists in the database, so nothing is
  lost — but making it count needs an engineer to add that row to the signer
  set (`Accounts.account_certs_pems`); listing it in `TRUSTED_CERTS` alone
  would not do it, for the reason above.

## 7. "Not on record" for older files

Only per-signer documents were fingerprinted before this page shipped.
Combined PDFs and audit-trail PDFs generated before Session 4 have an
EsignCenter signature but no record, so they show **Not on record**. Every
combined and audit-trail PDF generated since is recorded at signing time and
verifies normally; regenerating an old combined PDF records it too.

## 8. Where the page is linked

- The audit-trail PDF's "Verify" link points at `/verify`.
- Settings → E-Signature shows a "Verify a signed PDF" card that opens
  `/verify` in a new tab. The old in-app verification form (which showed
  certificate subjects and signer names to logged-in admins) is gone.
- The API endpoint `POST /api/tools/verify` is unchanged and still returns
  the detailed, authenticated answer for the caller's own account.
