# EsignCenter — Render deployment checklist (plain English)

EsignCenter runs as **its own service** on Render, completely separate from any
app that integrates with it. An integrating app only needs four settings
pointed at it (step 5).

**Production is an existing install being upgraded**, not a new one: the
service, database and bucket already exist and hold customer data. Sections 1–4
describe the setup for reference; for the upgrade itself start with
**"Before you deploy the upgrade"** below and then `docs/operations.md`
section 2.

## Before you deploy the upgrade

1. **Storage pre-check** on the live app (read-only, prints names only):
   `docs/operations.md` section 2.1 step 3. The new code reads storage from
   the environment only and refuses to boot rather than serve from the wiped
   container disk, so `S3_ATTACHMENTS_BUCKET` (and its AWS variables) must be
   on the service before the push.
2. **Rehearse the migrations on a restored copy** (`docs/operations.md`
   section 2.3), and on that copy run the **internal-account audit**,
   `bundle exec rake release:internal_audit` (step 5b there). It lists the
   internal apps' templates with formula fields — refused from this release
   on — and their webhook URLs the new rules refuse.
3. **Internal apps' webhooks now need HTTPS.** Every webhook, internal
   accounts included, must be `https://` on port 443 to a public address:
   `http://`, localhost and private-network (e.g. Render internal) addresses
   are refused. Move any endpoint the audit lists before deploying.
4. **Take the pre-deploy snapshot** (`docs/operations.md` section 2.2).
   **Rollback = restore that snapshot** and redeploy the previous commit: the
   migrations are not reversible, and a code-only rollback is not supported
   (section 2.8).
5. `bundle exec rake release:preflight` with the service's environment
   (section 3 below) must pass.

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
- **File storage** — an S3-compatible bucket (AWS S3, which production is
  recorded as using, or Cloudflare R2). Render's disk is wiped on every
  deploy, and production **refuses to boot** without a bucket. Set all of:
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
| `FORCE_SSL` | Exactly `true`. Production refuses to boot if it is missing or has another value. |
| `ADMIN_PROVISION_TOKEN` | A long random string — the integrating app uses this to create accounts. Generate a fresh one (`openssl rand -hex 32`). **Never reuse the `dev_prov_...` placeholder from `docker-compose.dev.yml`** — it is public, and the app refuses `dev_prov_` tokens in production anyway. Must match the integrating app's provisioning token. |

Also the S3/AWS variables from step 1 — `S3_ATTACHMENTS_BUCKET` is the
on/off switch, and production refuses to boot without it.

## 3. Custom domain + HTTPS

Add your subdomain (e.g. `esign.example.com`) to the web service, create
the CNAME record Render shows you, and wait for the certificate. **Everything
else assumes this domain works over HTTPS.**

Before changing any live service, load the proposed environment into a local
shell and run `bundle exec rake release:preflight`. It prints only variable
names and pass/fail states, never values. The command fails if the production
database/host/secret, timestamp authority, platform SMTP, or HTTPS setting is
missing, if no storage bucket is set, and it also fails if
`REGISTRATION_ENABLED` or `BILLING_ENABLED` is already on. A passing result establishes only that required values are present
and have safe shapes for a dark deploy. It does not verify credentials or
prove production readiness, and it does not replace the external backup,
email, Stripe, OAuth, or canary gates.

## 4. First boot check

This is an upgrade: the existing accounts and logins carry over. Open
`https://esign.<your-domain>/` and sign in with the existing admin login.
**If you see the setup page ("create the admin account"), stop** — the
service is pointed at an empty database; check `DATABASE_URL` before anything
else and do not create an account there.

Then open `https://esign.<your-domain>/up` — the health check. It returns
JSON like
`{"status":"ok","db":"ok","redis":"ok","scheduler_last_tick_at":"…","operator_account":"ok"}`
with HTTP 200; `"status":"degraded"` (HTTP 503) means the database or Redis
is unreachable. Point Render's health-check path at `/up`. Details in
`docs/operations.md` section 4.

On a brand-new instance `"operator_account"` will say `"missing"` — that is
expected, and it is the reminder that the platform-operator account has not
been created yet. **Nobody may sign anything until it says `"ok"`**: the one
signing certificate every customer's documents are signed with lives on that
account, so a document completed before the seed has nothing behind it. Run
the seed (step 2 of "After the deploy, in this order" below), then reload
`/up` and confirm `"operator_account":"ok"` before sending a single document.

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
the older, deprecated `X-Docuseal-Signature` — so an app can verify whichever
it already reads; new code should read `X-Esigncenter-Signature`, and an app
still on the old name should switch whenever convenient. A well-behaved
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
| `SMTP_ADDRESS` | **Required in production.** The platform's default mail server, e.g. `smtp.postmarkapp.com`. All platform notices and customer mail without an entitled account pin send through this; production refuses to boot when it is missing. |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | The credentials for that server (for Postmark, the EsignCenter server token in both). Production refuses to boot without this pair or `POSTMARK_API_TOKEN`. |
| `SMTP_FROM` | **Required in production.** The platform's From address, e.g. `EsignCenter <noreply@esigncenter.com>`. The app refuses to start without it so platform mail cannot go out under a tenant's From address. |
| `SMTP_ENABLE_STARTTLS`, `SMTP_ENABLE_SSL`, `SMTP_ENABLE_TLS`, `SMTP_SSL_VERIFY` | Leave unset for Postmark: STARTTLS and certificate verification default on. Production refuses to boot if verification is explicitly disabled, or if STARTTLS is disabled without direct SSL/TLS enabled. This guard applies to the platform server; verify legacy per-account pins separately in the parity check. |
| `TIMESERVER_URL` | **Required.** The trusted timestamp service stamped into signed PDFs (the DigiCert URL chosen in Session 0). Production refuses to boot without it, and a signing job whose timestamp request fails now errors and retries instead of embedding a fake time. Customer accounts always use this value. |
| `EMAIL_DELIVERY_MODE` | Leave unset. It defaults to `smtp` in production (real mail) and `test` everywhere else. Production refuses to boot if this is `test`; local development and the test suite may still use test mode. |
| `APP_URL` | Optional. The public HTTPS origin, e.g. `https://esign.example.com`. It may not contain credentials, a path, query, or fragment; production refuses to boot if it does. When unset the app builds links from `HOST` + `FORCE_SSL`, which is what production does today. |
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
2. **Create the platform-operator account — BEFORE any signing traffic:**
   `OPERATOR_EMAIL=you@example.com OPERATOR_PASSWORD=<strong password> bundle exec rake operator:seed`
   (safe to run twice — it says "already exists" and stops). Both variables
   are required; nothing secret is printed. Then enrol 2FA for that user —
   the operator surfaces (`/jobs`, the full-text toggle) need the operator
   flag **and** 2FA. See `docs/operations.md` section 7.
   **Check it worked by reloading `/up`: `"operator_account"` must say
   `"ok"`.** That field is the check — the platform signing certificate lives
   on this account, and a signing completed while it says `"missing"` produces
   no certificate-backed artefacts.
2b. **Export the platform signing certificate** into Evan's offline custody.
   The Render Shell cannot download files and the export holds private keys,
   so never print it there: export on the Mac from a restored copy of a
   backup taken after the seed, exactly as in `docs/operations.md` section
   8.2. Then run `bundle exec rake operator:platform_cert:fingerprint` in the
   Render Shell, confirm it matches the export, and record it in the
   operations notes.
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
6. **Watch all six scheduled jobs fire** (Sessions 5–10 added five of them;
   the times are UTC and they live in `config/schedule.yml`, which is the only
   place a recurring job is ever declared). Within the first day you should
   see each of these in the log, and `/jobs` shows them under *Cron*:

   | Job | When |
   | --- | --- |
   | `scheduler_heartbeat` | every minute — `/up` stops reporting a fresh `scheduler_last_tick_at` if it stops |
   | `housekeeping` | every hour at :05 — closes support sessions the operator walked away from and replays email callbacks that arrived early |
   | `billing_lifecycle` | every hour at :15 — the past-due reminder/suspension clock and the lapsed-invitation seat sweep |
   | `comp_expiry` | every hour at :45 — ends complimentary paid plans on their expiry date. The one job whose silent death gives paid access away for ever |
   | `stripe_reconciliation` | 06:00 — re-reads Stripe and repairs drift |
   | `account_retention` | 04:30 — the deletion and dormancy clocks, and the account-export housekeeping |

   The Scheduler tab in the operator console (`/operator/scheduler`) shows the
   same six with when each last ran, how long it took and whether it worked,
   and gives every business job a **Run now** button. What each job does and
   what it costs you when it stops is `docs/operations.md` section 4.1.

   The first tick to look for is the heartbeat (one minute). If nothing is
   firing at all, nothing time-based is running — see `docs/operations.md`
   section 4.
7. **Billing, only when you are opening the doors.** The steps that turn real
   money on are a checklist of their own and live in **`docs/billing.md`
   section 7**: with the **live** keys, create the live $10 monthly seat
   price, run `bundle exec rake stripe:api_prices` for the live Business
   ($49) and API pack ($10) prices and save the ids it prints, run
   `bundle exec rake stripe:portal_configuration` and put the `bpc_…` into
   `STRIPE_PORTAL_CONFIGURATION_ID`, add the webhook endpoint and copy its
   signing secret, then run `bundle exec rake stripe:check` — every price
   and the portal must say PASS, including **livemode** (a test-mode id
   left in place fails here and would refuse every sale) — and only then
   set `BILLING_ENABLED=true`.

   In the Stripe dashboard, also by hand: the **statement descriptor** is
   `ESIGNCENTER` (Settings → Public details), and **Stripe Tax threshold
   monitoring is ON with tax collection OFF** (decision D22: no sales tax is
   collected at launch; revisit when a state's economic-nexus threshold,
   typically about $100k a year, approaches; the accountant confirms the
   home-state Missouri rule). Under the same Public details, the **Terms of
   service URL** is `https://esigncenter.com/terms`: Checkout's required
   Terms and automatic-renewal consent box will not work without it, and
   every sale would fail.

   **One Stripe setting `rake stripe:check` cannot assert — set it by hand.**
   In the Stripe dashboard: **Settings → Billing → Subscriptions and emails →
   Manage failed payments**. The retry schedule must run **at least 14 days**
   (choose the longest window Stripe offers), and "after all retries fail"
   must be **Mark the subscription as unpaid** — never *Cancel*, never *Leave
   as is*. This is a dashboard-only value with no API behind it, so no command
   can confirm it and nothing will alert you if somebody changes it: it has to
   be looked at with your own eyes, at launch and after any Stripe settings
   change. Why it matters, and what goes wrong when it is short, is
   `docs/operations.md` section 3.4. Note the date and the window you chose in
   the deploy notes.

   **Before you run any Stripe command line tool against production, check
   which Stripe account it is logged into.** On the development machine the
   Stripe CLI's saved login is a *different* Stripe account from the one the
   app's key belongs to, and the CLI's "are you sure?" prompt prints the name
   of the account it is *logged in as*, not the one your key targets — so a
   destructive command can look like it is about to touch the right business
   when it is not. Export the key you actually mean to use
   (`export STRIPE_API_KEY=…`) and confirm with a harmless read
   (`stripe prices retrieve $STRIPE_PRICE_ID`) before anything that writes.

## Sessions 5–7 additions — what the deploy does on its own

Steps 6 and 7 above are the things you *do*. These are the things that happen
whether you do anything or not.

### What a Sessions 5–7 deploy does to people who are already using it

Three of the newer migrations are visible to customers or change a clock. None
of them needs an action from you, but somebody will ask:

- **Everyone signs in again on the day this ships.** `20260904041500` adds
  `users.session_version`, which becomes part of what every browser session
  cookie is checked against. Adding it changes that check once for every
  existing user, so every signed-in browser and every "remember me" cookie is
  signed out at the deploy and people sign in again. It is a one-off, it
  affects **humans only**, and it happens on its own — nothing to run.
  **Do not warn customers or the integrating apps:** API tokens, MCP tokens
  and the provisioning/webhook credentials the integrating apps use are a
  different credential entirely and are untouched, so no integration goes
  dark. In-flight signing is unaffected too — signers are not signed-in users.
- **Accounts part-way through a dormancy warning restart their notice.**
  `20260904050000` adds `accounts.last_active_at`, the "somebody is actually
  using this" stamp, which from now on is written at most once a day when a
  signed-in member makes a request. Existing rows are deliberately left empty
  (there is no honest value to invent for the past), so nobody's dormancy
  clock moves — but any account already inside its 60/30/7-day dormancy notice
  has that notice cleared and starts it again under the new, fairer
  definition. The visible cost is one repeated round of dormancy warning
  emails to accounts that really are abandoned; the alternative was deleting a
  live customer's account during the deployment window.
- **Orphaned webhook attempt rows are deleted.** `20260904040000` puts a real
  foreign key on `webhook_attempts.webhook_event_id` (and makes deleting an
  event take its attempts with it). Any attempt row whose event no longer
  exists is deleted first, because the constraint cannot be created while such
  rows are there. Count them on the rehearsal copy before you deploy — the
  query and what to do with the answer are in `docs/operations.md`
  section 2.3, step 4b.

## Sessions 8–10 additions — what the deploy does on its own

Thirteen more migrations arrived with the operator console, the account
export, the legal record and the billing fixes. **None of them destroys data
and none of them needs an action from you** — every one adds a column, a table
or an index. Three things are worth knowing anyway:

- **One migration can stop the deploy on purpose.** `20260906090000` adds a
  rule the database enforces from now on: one party per role, per document. It
  refuses to be added while any existing document holds two people in the same
  role, and prints the first twenty. That is deliberate — deciding which of two
  people really holds a role is a human judgement, not something a migration
  should guess. Catch it on the rehearsal copy, not on production: the full
  procedure is `docs/operations.md` section 2.3, "Duplicate submitter uuids".
- **Three indexes are built `CONCURRENTLY`**, which keeps signing working
  while they are created but leaves an unusable index behind if a build is
  interrupted — and a re-run then skips it silently. After *any* failed or
  interrupted migration run, follow "Indexes built CONCURRENTLY" in
  `docs/operations.md` section 2.3 before running the migrations again. This
  applies on production too, not only on the rehearsal copy.
- **Nothing customers see changes at the deploy.** No sign-outs, no clocks
  reset, no rows rewritten: new comp expiry dates, exports, legal-acceptance
  records and the Stripe `cancel_at` date all start empty and fill in as they
  are used. The full list, row by row, is the second migration table in
  `docs/operations.md` section 2.

## Launch gate 4b — Sign in with Apple

The **Continue with Apple** button is built and switched off. It appears the
moment four environment variables hold real values, and stays invisible until
then (`docs/signup.md`, *Turning the Apple button on*). This is the errand
that produces those four values. Allow about half an hour, plus however long
Apple takes to verify the domain — usually minutes.

You need an **Apple Developer Program** membership ($99/year) for the account
that will own the sign-in. Everything below happens at
<https://developer.apple.com/account>, under **Certificates, Identifiers &
Profiles**.

1. **Find your team id.** Top right of the developer account page, under
   *Membership details* — ten characters, e.g. `AB1234CD56`. That is
   `APPLE_OAUTH_TEAM_ID`.

2. **Create an App ID.** *Identifiers* → **+** → *App IDs* → *App*.
   Description: `EsignCenter`. Bundle ID: explicit, e.g.
   `com.esigncenter.signin`. In the Capabilities list tick **Sign In with
   Apple**. Register. (Apple requires an App ID to exist even though we are a
   website; nothing else uses it.)

3. **Create a Services ID — this is the client id.** *Identifiers* → **+** →
   *Services IDs*. Description: `EsignCenter Web`. Identifier: e.g.
   `com.esigncenter.web` — it must be different from the App ID above.
   Register, then open it again and tick **Sign In with Apple** →
   **Configure**:
   - Primary App ID: the App ID from step 2.
   - **Domains and Subdomains:** `esigncenter.com` (add `www.esigncenter.com`
     too if the site answers there).
   - **Return URLs:** `https://esigncenter.com/auth/apple/callback` — exactly
     that path, and one line per domain you listed. HTTPS only; Apple rejects
     `http://` and rejects `localhost`, which is why this cannot be tested on
     a laptop.
   Save. The Services ID identifier is `APPLE_OAUTH_CLIENT_ID`.

4. **Verify the domain.** In the same Configure panel Apple offers
   *Download* for a file named `apple-developer-domain-association.txt`. It
   has to answer at
   `https://esigncenter.com/.well-known/apple-developer-domain-association.txt`.
   This app serves anything under its `public/` folder, so the file goes to
   `public/.well-known/apple-developer-domain-association.txt` in the repo and
   ships with the next deploy — a one-line job for the engineer. Load the URL
   in a browser to confirm it returns the file, then press **Verify** in
   Apple's panel. A domain that is not verified makes every sign-in attempt
   fail with *invalid_client*.

5. **Create the sign-in key.** *Keys* → **+**. Key Name: `EsignCenter Sign In`.
   Tick **Sign In with Apple** → **Configure** → choose the App ID from
   step 2 → Save → **Continue** → **Register**. Apple now shows a **ten
   character Key ID** — that is `APPLE_OAUTH_KEY_ID` — and lets you
   **Download** a file called `AuthKey_XXXXXXXXXX.p8` **once and only once**.
   Download it and keep it somewhere safe; Apple will never show it again and
   a lost key means creating a new one.

6. **Put the four values into Render.** Web service → *Environment*:
   - `APPLE_OAUTH_CLIENT_ID` — the Services ID from step 3
     (`com.esigncenter.web`).
   - `APPLE_OAUTH_TEAM_ID` — the ten characters from step 1.
   - `APPLE_OAUTH_KEY_ID` — the ten characters from step 5.
   - `APPLE_OAUTH_PRIVATE_KEY` — the **whole contents** of the `.p8` file,
     including the `-----BEGIN PRIVATE KEY-----` and
     `-----END PRIVATE KEY-----` lines. Paste it with its line breaks; if
     Render's editor collapses it, `\n` between the lines works too.
   Save, which redeploys.

7. **Check it.** The site must be served over HTTPS — Apple's sign-in returns
   the browser to us in a way that only works over HTTPS, and the session
   cookie it needs is marked `Secure` from the browser's own scheme (Render
   passes it through as `X-Forwarded-Proto`), not from `FORCE_SSL`. Leave
   `FORCE_SSL` at `true` anyway (it is, in the table in section 2), so a plain
   http:// visit is redirected rather than served. Then open
   `https://esigncenter.com/sign_in` in a private window: a
   black **Continue with Apple** button now sits under the Google one. Press
   it, sign in with an Apple ID, and choose **Share My Email**. You should
   land signed in, with a new account carrying the four sample documents.
   If the button is not there, one of the four values did not take — the boot
   log says which.

Two things worth knowing before you test:

- **Apple hands over the email address only the first time.** If your first
  attempt fails for any reason, the second one arrives with no address and the
  page will tell you to remove EsignCenter from *Settings → your name → Sign
  in with Apple* on your device and try again. That is expected, not a bug.
- **Hide My Email is fine.** If a customer chooses it, we store the
  `@privaterelay.appleid.com` forward Apple gives us. Mail to it reaches them.

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

The "DocuSeal" word in that footer links to DocuSeal's own source repository
(`https://github.com/docusealco/docuseal`), never to their sign-up page: the
credit owes a reader the upstream project, not a competitor's sales funnel.
`rake gates:branding` fails the build if the link moves, if either attribution
partial loses it, or if any page that shows the footer today stops rendering
it.
