# EsignCenter — Render deployment checklist (plain English)

EsignCenter runs as **its own service** on Render, completely separate from the
VA Claim Net app. The app only needs four settings pointed at it (step 7).

## 1. Create the services on Render

- **Web service** — build from this repo's `Dockerfile`. Plan: at least
  **Standard** (the PDF work needs the memory).
- **PostgreSQL database** — Render managed Postgres (Basic is fine to start).
  Copy its **Internal Database URL**.
- **File storage** — Render's disk is wiped on every deploy, so signed PDFs
  must live in real storage. Two options:
  - *Simplest:* attach a **Render Persistent Disk** to the web service,
    mounted at `/data/docuseal` (10 GB to start).
  - *Most robust:* an S3-compatible bucket (AWS S3 or Cloudflare R2). The
    variable that actually switches storage to S3 is `S3_ATTACHMENTS_BUCKET`
    — without it, files silently stay on the wipeable disk. Set all of:
    `S3_ATTACHMENTS_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
    `AWS_REGION` (and `S3_ENDPOINT` if using Cloudflare R2).

Redis is **built in** (it starts inside the web service automatically) — you
do not need a separate Redis unless you later run more than one instance. If
you ever scale to 2+ instances, add a managed Redis and set `REDIS_URL`.

## 2. Environment variables on the web service

| Variable | What to put there |
| --- | --- |
| `DATABASE_URL` | The Internal Database URL from step 1 |
| `SECRET_KEY_BASE` | A long random string — generate once, never change it |
| `HOST` | The service's domain, e.g. `esign.vaclaimnet.com` |
| `FORCE_SSL` | `true` |
| `ADMIN_PROVISION_TOKEN` | A long random string — the app uses this to create firm accounts. Must match the app's `DOCUSEAL_ADMIN_PROVISION_TOKEN`. |

(If you chose S3/R2 storage, also add the S3/AWS variables from step 1 —
remember `S3_ATTACHMENTS_BUCKET` is the on/off switch.)

## 3. Custom domain + HTTPS

Add your subdomain (e.g. `esign.vaclaimnet.com`) to the web service, create
the CNAME record Render shows you, and wait for the certificate. **Everything
else assumes this domain works over HTTPS.**

## 4. First boot check

Open `https://esign.<your-domain>/` — you should see the EsignCenter setup
page. Create the admin account and keep the password in your password
manager. This admin login is for YOU only; firms never see it.

**Order matters when UPGRADING:** always deploy this fork's update **before**
the app's update. An older fork can't attach the webhook auth header the
newer app expects, which would leave newly-connected firms with silent,
non-authenticating webhooks (statuses would ride the 10-minute re-check
only, and the app logs an `[esign-provision]` error).

## 5. Point the app at it

In the **VA Claim Net** Render environment group, fill in:

| App variable | Value |
| --- | --- |
| `DOCUSEAL_BASE_URL` | `https://esign.<your-domain>` |
| `DOCUSEAL_ADMIN_PROVISION_TOKEN` | Same value as the fork's `ADMIN_PROVISION_TOKEN` |
| `DOCUSEAL_API_TOKEN` | Leave unset — firm tokens are minted automatically |
| `DOCUSEAL_WEBHOOK_SECRET` | Leave unset — per-firm secrets are minted automatically |

Webhooks (the fork telling the app "someone signed") are configured
automatically when a firm's e-sign account is provisioned: the fork calls
`https://app.<your-domain>/api/esigncenter/webhook`, signing every delivery
with a per-firm key the app captures at provisioning and verifies. The app
also re-checks every document on a 10-minute schedule, so even a missed
webhook only delays a status by a few minutes. (Firms provisioned by an older
version authenticate with their original shared secret and keep working.)

## 6. After the FIRST deploy that includes the prefill-mapping fixes

Run once, from the app's Render shell (or a one-off job):

```
pnpm refresh:builtin-mappings
```

This refreshes every firm's built-in VA form mappings (and customized copies)
so the corrected field placements take effect for already-provisioned firms.

## 7. Smoke test (10 minutes)

1. In the app, open a client → Forms & signatures → send a **VA Form 21-4138**
   to yourself as the client.
2. Check the prefill review in the send dialog shows "boxes will fill".
3. Sign the rep part — the Complete button should be visible immediately.
4. Open the client portal invite email → agree to the e-sign consent → sign.
5. Confirm the dashboard shows Signed, the PDF + certificate download, and
   the client got the "Signed and complete" email with portal links.

## Legal note (open-sourcing the fork)

The fork is AGPL-3.0 with DocuSeal's additional terms: the **"Powered by
DocuSeal" attribution in the signing screens must stay** (it does — footer),
and the fork's complete source must remain publicly available (it is — this
repository). The corner logo was removed; that is allowed. Do not remove the
footer attribution.
