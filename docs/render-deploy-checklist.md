# EsignCenter — Render deployment checklist (plain English)

EsignCenter runs as **its own service** on Render, completely separate from any
app that integrates with it. An integrating app only needs four settings
pointed at it (step 5).

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
| `HOST` | The service's domain, e.g. `esign.example.com` |
| `FORCE_SSL` | `true` |
| `ADMIN_PROVISION_TOKEN` | A long random string — the integrating app uses this to create accounts. Generate a fresh one (`openssl rand -hex 32`). **Never reuse the `dev_prov_...` placeholder from `docker-compose.dev.yml`** — it is public, and the app refuses `dev_prov_` tokens in production anyway. Must match the integrating app's provisioning token. |

(If you chose S3/R2 storage, also add the S3/AWS variables from step 1 —
remember `S3_ATTACHMENTS_BUCKET` is the on/off switch.)

## 3. Custom domain + HTTPS

Add your subdomain (e.g. `esign.example.com`) to the web service, create
the CNAME record Render shows you, and wait for the certificate. **Everything
else assumes this domain works over HTTPS.**

## 4. First boot check

Open `https://esign.<your-domain>/` — you should see the EsignCenter setup
page. Create the admin account and keep the password in your password
manager. This admin login is for YOU only; provisioned accounts never see it.

**Order matters when UPGRADING:** always deploy this fork's update **before**
the integrating app's update. An older fork can't attach the webhook auth
header a newer app expects, which would leave newly-connected accounts with
silent, non-authenticating webhooks (statuses would ride the periodic
re-check only, and the integrating app logs a provisioning error).

## 5. Point the integrating app at it

In the integrating app's environment settings, fill in (variable names may
differ in your app):

| App variable | Value |
| --- | --- |
| `DOCUSEAL_BASE_URL` | `https://esign.<your-domain>` |
| `DOCUSEAL_ADMIN_PROVISION_TOKEN` | Same value as the fork's `ADMIN_PROVISION_TOKEN` |
| `DOCUSEAL_API_TOKEN` | Leave unset — per-account tokens are minted automatically |
| `DOCUSEAL_WEBHOOK_SECRET` | Leave unset — per-account secrets are minted automatically |

Webhooks (the fork telling the app "someone signed") are configured
automatically when an e-sign account is provisioned: the fork calls the
webhook URL the app registers, signing every delivery with a per-account key
the app captures at provisioning and verifies. A well-behaved integrating app
should also re-check documents on a schedule, so even a missed webhook only
delays a status by a few minutes. (Accounts provisioned by an older version
authenticate with their original shared secret and keep working.)

## 6. After a deploy that changes built-in field mappings

If your integrating app keeps its own copies of field mappings for templates,
refresh them once after deploying, so corrected field placements take effect
for already-provisioned accounts. (How to do that depends on the app — it is
usually a one-off script or admin task on the app's side.)

### Browser caching of the signing/builder JavaScript

The compiled JavaScript bundles keep the same filenames across deploys, and
older builds told browsers to cache them for up to 6 months — so people could
keep seeing OLD buttons/behavior long after a deploy. That is fixed (browsers
now re-check on every load), but anyone who used the signing screens **before**
this deploy may need one hard refresh (Cmd+Shift+R) to pick up the fix itself.

## 7. Smoke test (10 minutes)

1. From the integrating app, send a document to yourself as the recipient.
2. If the app prefills fields, check the send dialog shows the expected
   prefilled boxes.
3. Sign the sender's part — the Complete button should be visible immediately.
4. Open the recipient invite email → agree to the e-sign consent → sign.
5. Confirm the app shows Signed, the PDF + certificate download, and the
   recipient got the completion email.

## Legal note (open-sourcing the fork)

The fork is AGPL-3.0 with DocuSeal's additional terms: the **"Powered by
DocuSeal" attribution in the signing screens must stay** (it does — footer),
and the fork's complete source must remain publicly available (it is — this
repository). The corner logo was removed; that is allowed. Do not remove the
footer attribution.
