# EsignCenter — Render deployment checklist (plain English)

EsignCenter runs as **its own service** on Render, completely separate from any
app that integrates with it. An integrating app only needs four settings
pointed at it (step 5).

## 1. Create the services on Render

- **Web service** — build from this repo's `Dockerfile`. Plan: at least
  **Standard** (the PDF work needs the memory, and Word-to-PDF conversion
  runs LibreOffice inside the same container — see `docs/word-uploads.md`).
  The image is about **800 MB larger** since LibreOffice Writer and its fonts
  were added (Session 4, decision D48): expect slower builds and first
  deploys. `WORD_CONVERSION_ENABLED=false` switches Word uploads off without
  a rebuild.
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
Whether to move to managed Redis before launch is decided at launch-gate 3
from the analysis in `docs/operations.md` section 5.

**Launch gate on staging:** confirm `/verify` is rate-limited per visitor
behind Cloudflare and Render. On the first network, measure the public IP with
`curl -s https://api.ipify.org`, POST to `/verify`, and inspect Redis. The
`rate_limit:verify-minute-<ip>` key must contain that measured IP. Repeat from
a second network; it must create a second key containing that network's own
measured public IP.

Then try spoofed headers. POST with `-H 'X-Forwarded-For: 9.9.9.9'`, then with
`-H 'Forwarded: for=9.9.9.9'`, and again with
`-H 'Forwarded: for=8.8.8.8'`. No `rate_limit:verify-minute-9.9.9.9` or
`rate_limit:verify-minute-8.8.8.8` key may ever appear. A POST with
`-H 'Client-Ip: 9.9.9.9'` must return 200 or 429, never 500. Finally, send 11
POSTs inside one minute from the first network: the first ten must return 200
and the eleventh 429, while a POST from the second network still returns 200.

The limiter fails open when Redis is unavailable. If a POST returns 200 but
no rate-limit keys appear at all, Redis is down; that is not a passing test.

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

Then open `https://esign.<your-domain>/up` — the health check. It returns
JSON like `{"status":"ok","db":"ok","redis":"ok","scheduler_last_tick_at":"…"}`
with HTTP 200; `"status":"degraded"` (HTTP 503) means the database or Redis
is unreachable. Point Render's health-check path at `/up`. Details in
`docs/operations.md` section 4.

### Word conversion memory check (launch-gate 3)

Word uploads are converted to PDF by LibreOffice **inside the web
container**, next to Puma, the embedded Sidekiq and the embedded Redis. If
the container runs out of memory, Render kills the whole thing — web server,
queued jobs and all. This check proves the headroom is there before customers
can upload Word files. Do it once on staging (or the production service before
launch), with the same instance plan you will run in production.

1. **Baseline.** With nothing running, note the container's idle memory on
   Render's *Metrics* → *Memory* graph. If you want the number from inside
   the container instead, open a shell on the service and run
   `ps -o rss,cmd -p 1 --ppid 1` (the `puma` line is Puma plus the embedded
   Sidekiq; the figure is in KB). Write both down next to the plan's memory
   limit (shown on the plan's page in the Render dashboard).
2. **Worst case.** Prepare two `.doc` files close to the 20 MB cap (a long
   document full of images does it). From two browser tabs, upload both to
   the dashboard **at the same time**, so both conversions run at once (the
   default `WORD_CONVERSION_SLOTS` is 2). Watch the memory graph while the
   converting cards spin. Each LibreOffice process can take a few hundred
   megabytes on a file this size, so expect the peak to sit at roughly
   *baseline + 2 × a few hundred MB*.
3. **Verdict.** The check passes when the peak stays clearly below the plan's
   limit — leave at least a quarter of the limit free, since Render kills
   the container at the limit and PDF signing has spikes of its own. Record
   the baseline, the peak and the plan in the launch-gate notes.
4. **If it does not fit,** in this order, none of which needs a redeploy:
   - set `WORD_CONVERSION_SLOTS=1` (one conversion at a time) and run the
     check again with one upload;
   - if even one does not fit, set `WORD_CONVERSION_ENABLED=false` (Word
     uploads off; anything still queued is marked failed without LibreOffice
     starting) until the next step;
   - move to a larger instance plan and repeat from step 1.

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
the app captures at provisioning and verifies. Every delivery now carries the
signature in two headers with the same value — `X-Esigncenter-Signature` and
the older `X-Docuseal-Signature` — so an app can verify whichever it already
reads and switch to the new name whenever convenient. A well-behaved
integrating app should also re-check documents on a schedule, so even a missed
webhook only delays a status by a few minutes. (Accounts provisioned by an
older version authenticate with their original shared secret and keep
working.)

The provisioning call (`POST /api/admin/accounts`) accepts an optional
`idempotency_key` — any string the integrating app makes up once per
"create this workspace" request and sends again on a retry. What it buys
you: if the network drops after the account was created but before the app
saw the reply, re-sending the same request with the same key returns the
original account and its credentials again with status **200** instead of
creating a duplicate. If the same key is ever re-sent with a *different* email,
the fork refuses with status **409** and touches nothing (the key belongs to
the first request). Each replay and each refusal is written to the server log
with the account id and the key, never the credentials.

## Session 1 additions (per-account settings, email, kill switches)

Session 1 of the standalone-SaaS work changed how the fork finds its settings:
every account now uses **its own** email server and templates instead of
silently borrowing account #1's. Internal accounts also keep their own signing
certificate; customer accounts sign with the platform certificate described
in section 8 of `docs/operations.md`. This section lists the new environment
variables, what the upgrade does to accounts that already exist, and the steps
to run right after the deploy.

### New environment variables

**The complete, current manifest — every variable, where it is read, and
what happens when it is missing — lives in `docs/operations.md` section 3.**
That table is authoritative; the one below is the Session 1 subset kept for
context.

| Variable | What to put there |
| --- | --- |
| `SMTP_ADDRESS` | The platform's default mail server, e.g. `smtp.postmarkapp.com`. Any account without its own pinned server sends through this. |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | The credentials for that server (for Postmark, the EsignCenter server token in both). |
| `SMTP_FROM` | The platform's From address, e.g. `EsignCenter <noreply@esigncenter.com>`. **Boot rule:** if `SMTP_ADDRESS` is set and `SMTP_FROM` is not, the app refuses to start in production — otherwise platform mail would go out under a tenant's From address. Set both or neither. |
| `TIMESERVER_URL` | **Required.** The trusted timestamp service stamped into signed PDFs (the DigiCert URL chosen in Session 0). Production refuses to boot without it, and a signing job whose timestamp request fails now errors and retries instead of embedding a fake time. Customer accounts always use this value. |
| `EMAIL_DELIVERY_MODE` | Leave unset. It defaults to `smtp` in production (real mail) and `test` everywhere else (mail is captured, never sent). Set it explicitly only to force one of those two values; anything else refuses to boot. |
| `APP_URL` | Optional. The full public URL, e.g. `https://esign.example.com`. When unset the app builds links from `HOST` + `FORCE_SSL`, which is what production does today. |
| `REGISTRATION_ENABLED` | Leave unset (off). Public sign-up is dark until a later session flips it to `true`. |
| `BILLING_ENABLED` | Leave unset (off). Same idea for billing. |
| `CERTS` | **No longer read (Session 4).** Nothing in the app looks at this variable any more, so a leftover value is inert — no need to check it. Customers sign with the one platform certificate held by the operator account; see section 8 of `docs/operations.md`. |
| `MULTITENANT` | **Must stay unset.** The fork runs single-tenant by design. |

One-off values used only by the post-deploy tasks below: `OPERATOR_EMAIL`
and `OPERATOR_PASSWORD` (**both required** since Session 2 — the task aborts
without them and never generates or prints a password; remove them from the
service after the seed), plus one environment variable per internal app
holding that app's own Postmark server token (name it whatever you like;
`email:pin` reads it by name).

### What the upgrade does to existing accounts

The migrations run automatically on boot and take seconds. They add an account
"kind" (every existing account becomes *internal* — your own apps, account #1,
and their test-mode twins), mark every existing user's email as confirmed, add
an audit table for provisioning calls, and copy from account #1 to each other
pre-existing account — only where that account has nothing of its own — the
things that used to apply to everyone: the four email-template/reminder
settings, the PDF signature-reason preference, the signing certificate, the
pinned SMTP server, and the timeserver URL. Nothing is deleted on production,
and nothing changes for an account that already had its own value. One visible
difference: mail that used to show account #1's name as the sender now shows
each account's own name.

### After the deploy, in this order

1. **Check the migration log.** Render runs `rake db:migrate` on boot; the log
   should show the migrations completing and the line
   `removing 0 over-copied account_configs row(s)`.
2. **Create the platform-operator account:**
   `OPERATOR_EMAIL=you@example.com OPERATOR_PASSWORD=<strong password> bundle exec rake operator:seed`
   (safe to run twice — it says "already exists" and stops). Both variables
   are required; nothing secret is printed. Then enrol 2FA for that user —
   the operator surfaces (`/jobs`, the full-text toggle) need the operator
   flag **and** 2FA. See `docs/operations.md` section 7.
2b. **Export the platform signing certificate to a fresh path:**
   `bundle exec rake "operator:platform_cert:export[/tmp/esigncenter-platform-cert-YYYYMMDD.pem]"`.
   Store the exported file offline in Evan's custody, then run
   `bundle exec rake operator:platform_cert:fingerprint` and record its output
   in the operations notes. Replace `YYYYMMDD` and use a path that does not
   already exist; the `0600` owner-only permission is guaranteed when the task
   creates the fresh file.
3. **Review every pinned mail server:** `bundle exec rake email:pins` prints one
   line per account that has its own SMTP server — account id, kind, name,
   host, From address, and whether the pin is usable. It never prints
   credentials. Unpin (`ACCOUNT_ID=<id> bundle exec rake email:unpin`) or re-pin
   any row you do not recognise; after the migration expect one row per
   pre-existing non-testing account (test-mode twins inherit their parent's),
   all copied from account #1.
4. **Pin each internal app to its own Postmark server:**
   `ACCOUNT_ID=<id> SMTP_TOKEN_ENV=<NAME_OF_TOKEN_VAR> FROM_EMAIL=<verified sender> bundle exec rake email:pin`
   — once per internal app account. The From address must be a sender
   signature or domain verified on that Postmark server, or Postmark rejects
   the mail. Safe to re-run; it overwrites the pin.
5. **Canary.** From one internal app, send a document to yourself: the invite
   email should arrive from that app's own server, signing should complete, the
   completion email should arrive, and the app's webhook should verify. Then
   check the log has no `no SMTP config for account` lines.

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
