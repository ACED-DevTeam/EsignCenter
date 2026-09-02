# EsignCenter — Operations guide (plain English)

This is the runbook for running EsignCenter in production. It is written for
the product owner, not a developer: every step has the exact command, and
technical terms are defined the first time they appear.

Production today: one **Render** Docker web service (Render builds the
`Dockerfile` and restarts the service on every push to `master`), a Render
managed **PostgreSQL 16** database, signed PDFs and uploads in an **AWS S3**
bucket, and **Redis** (a small in-memory data store the job system uses)
running *inside* the web container. The two launch switches
`REGISTRATION_ENABLED` and `BILLING_ENABLED` are off unless set to `true`, so
a deploy is never a launch.

Where commands run:

- **Render Shell** — the Shell tab on the web service in the Render dashboard.
  It opens a terminal inside the running container. `bundle exec rails
  console` there gives you a Ruby prompt with the production database loaded;
  `bundle exec rake <task>` runs a maintenance task.
- **Local** — your Mac, in the repo folder. Used for the migration rehearsal
  and the code gates.

Contents:

1. [Backup and restore](#1-backup-and-restore)
2. [Deploy runbook](#2-deploy-runbook)
3. [Environment variable manifest](#3-environment-variable-manifest)
4. [Health check and scheduler heartbeat](#4-health-check-and-scheduler-heartbeat)
5. [Redis: embedded vs managed](#5-redis-embedded-vs-managed)
6. [Postmark: moving to a separate account](#6-postmark-moving-to-a-separate-account)
7. [What Session 2 changed for operators](#7-what-session-2-changed-for-operators)
8. [Signing certificates and timestamps](#8-signing-certificates-and-timestamps)

---

## 1. Backup and restore

What needs backing up, and where it lives:

| Data | Lives in | Backed up by |
| --- | --- | --- |
| Accounts, users, templates, submissions, audit data, per-account settings | Render PostgreSQL | Render's automatic database backups |
| Signing certificates (each account's `esign_certs` row), pinned SMTP servers, timeserver URLs | The `encrypted_configs` table in the same database — **encrypted with a key derived from `SECRET_KEY_BASE`** | Same database backup **plus** an offline copy of `SECRET_KEY_BASE` |
| Signed PDFs, uploaded documents, signature images | S3 bucket (`S3_ATTACHMENTS_BUCKET`) | S3 bucket versioning (see 1.1) |
| Job queues, rate-limit windows, scheduler heartbeat | Redis inside the container | Not backed up — by design, see section 5 |

**The signing key rule.** The platform signing certificate is only readable
with `SECRET_KEY_BASE` (or `ENCRYPTION_SECRET` if you ever set one). A
database backup without that value is a box you cannot open. Keep a copy of
`SECRET_KEY_BASE` in your password manager, separate from Render, and never
rotate it — rotating it makes every encrypted row (certificates, SMTP pins)
unreadable.

### 1.1 Confirm the automatic backups exist (once, then quarterly)

1. Render dashboard → the `esigncenter-db` database → its Backups section.
   Confirm daily backups are listed and note the retention period. (Backup
   frequency and retention depend on the database plan — verify in the
   dashboard rather than assuming.)
2. AWS console → the S3 bucket → Properties → **Bucket Versioning** must be
   **Enabled**. Versioning keeps every prior version of a file, so an
   accidental delete or overwrite can be undone. If it is off, turn it on;
   nothing else changes.
3. Optional but recommended: an S3 lifecycle rule that moves old versions to
   cheaper storage after 30 days instead of deleting them.

### 1.2 Restore test (launch gate 1, then twice a year)

The goal is to prove a backup can be turned back into a working database —
including the encrypted signing key — without touching production.

1. In the Render dashboard, restore the latest backup **into a new, separate
   database** (Render restores to a fresh instance; it never overwrites the
   live one). Name it `esigncenter-restore-test`. Copy its **External
   Database URL** (the one reachable from outside Render).
2. From the Render Shell of the web service, point a Rails console at the
   restored copy. `DATABASE_URL` is read at boot, so it can be overridden for
   one command:

   ```sh
   DATABASE_URL='<external url of esigncenter-restore-test>' RUN_MIGRATIONS=false bundle exec rails console
   ```

3. In that console, verify the counts match what you expect from production
   (compare against the same queries on the live console):

   ```ruby
   puts({ accounts: Account.count, users: User.count, templates: Template.count,
          submissions: Submission.count, submitters: Submitter.count,
          configs: EncryptedConfig.count, counters: AccountCounter.count })
   ```

4. Prove the signing key decrypts — this is the step that fails if
   `SECRET_KEY_BASE` were ever lost:

   ```ruby
   cert = EncryptedConfig.where(key: 'esign_certs').order(:account_id).first
   puts cert.account_id, cert.value.keys.inspect   # expect the certificate field names, no error
   ```

   Also check an SMTP pin decrypts (never print the credentials):

   ```ruby
   pin = EncryptedConfig.where(key: 'action_mailer_smtp').order(:account_id).first
   puts pin.account_id, pin.value['host'], pin.value['from_email']
   ```

5. Prove a file is readable from S3 for one submission (in the same console):

   ```ruby
   att = ActiveStorage::Attachment.order(:id).last
   puts att.blob.service.exist?(att.blob.key)   # expect true
   ```

6. Exit the console. Use this restored copy for the migration rehearsal in
   section 2 if a deploy is pending; otherwise delete
   `esigncenter-restore-test` in the dashboard so it stops costing money.

### 1.3 Real restore (something went badly wrong)

1. Put the service into a safe state first: on Render, set
   `REGISTRATION_ENABLED` and `BILLING_ENABLED` to unset/`false` if they were
   on (each env change restarts the service).
2. Restore the chosen backup into a new database as in 1.2 step 1.
3. Run the 1.2 verification (steps 2–5) against it.
4. Point production at it: on the web service, change `DATABASE_URL` to the
   new database's **Internal** URL. Render restarts the service; migrations
   run on boot.
5. Check `https://<your host>/up` returns `"status":"ok"` (section 4), then
   run the internal-account canary from section 2.6.
6. Files in S3 were not touched by the database restore. If files were also
   damaged, restore individual objects from their prior version in the S3
   console (Versioning must have been on).

---

## 2. Deploy runbook

Every push to `master` rebuilds production. Use this sequence for any deploy
that includes database migrations (a **migration** is a script that changes
the database's shape or data; Rails runs pending ones automatically when the
container boots). The Session 1 and 2 migrations are the model:

| Migration | What it does |
| --- | --- |
| `20260901090000` | Adds `account_kind` to accounts (default `customer`) and `platform_operator` to users |
| `20260901090100` | Marks every existing account `internal`; confirms every existing user's email. **Cannot be rolled back.** |
| `20260901090200` | Creates the `provisioning_events` audit table |
| `20260901090300` | Copies the five settings that used to be global (email templates, reminders, signature-reason preference) from the lowest-id account to older accounts that lack them. Cannot be rolled back. |
| `20260901090400` | Same copy for the signing certificate. Cannot be rolled back. |
| `20260901090500` | Cleans up an earlier over-copy — expects to log `removing 0 over-copied account_configs row(s)` on production |
| `20260901090600` | Same copy for the pinned SMTP server and the timeserver URL. Cannot be rolled back. |
| `20260901180000` | Creates the `account_counters` table (durable per-account counters) |

Because most of these are one-way, **rollback of the database is a restore
from the pre-deploy snapshot**, never `db:rollback`.

### 2.1 Before you start

1. Confirm on Render that `MULTITENANT` is **not set**. The old
   "confirm `CERTS` is unset" step is **moot**: Session 4 deleted `CERTS`
   from the code, so a leftover value on the service does nothing at all
   (section 8). `TIMESERVER_URL` must be set — production refuses to boot
   without it.
2. Confirm `HOST` on Render equals the host in the old app-URL setting, or
   set `APP_URL` explicitly. Every link in every email and webhook is built
   from this. Check the old value from the Render Shell:

   ```sh
   bundle exec rails runner 'puts EncryptedConfig.where(key: "app_url").pluck(:account_id, :value).inspect'
   ```

3. Run the code gates locally on the exact commit you are about to deploy.
   They grep the code for tenant-isolation leaks and banned test patterns;
   they do not touch production:

   ```sh
   docker compose -f docker-compose.dev.yml exec -T -e RAILS_ENV=test app bundle exec rake gates:all
   ```

### 2.2 Snapshot

1. Render dashboard → `esigncenter-db` → take a manual backup now (or note
   the timestamp of the latest automatic one — it must be from *after* the
   last customer-visible activity you care about).
2. Record the pre-deploy facts you will compare afterwards, from the Render
   Shell:

   ```sh
   bundle exec rails runner '
     puts "smtp/timeserver rows: " + EncryptedConfig.where(key: %w[action_mailer_smtp timestamp_server_url]).pluck(:account_id, :key).inspect
     puts "esigning_preference: " + AccountConfig.where(key: "esigning_preference").pluck(:account_id, :value).inspect
     puts "accounts: #{Account.count}, customer-kind: #{Account.where(account_kind: "customer").count}"
   '
   ```

   Keep the output in the deploy notes.

### 2.3 Migration rehearsal on the restored copy

Run the new code's migrations against a *copy* of production first, so a
migration that fails or does something surprising is caught on a throwaway
database.

1. Restore the snapshot into `esigncenter-rehearsal` (section 1.2 step 1) and
   copy its External Database URL.
2. Locally, build the image from the commit you will deploy:

   ```sh
   docker build -t esigncenter-release .
   ```

3. Create a local, gitignored env file for the rehearsal — it needs the
   production `SECRET_KEY_BASE` so encrypted rows stay decryptable. Write it
   from your clipboard rather than typing secrets into the terminal history:

   ```sh
   printf 'RAILS_ENV=production\nRUN_MIGRATIONS=false\nDATABASE_URL=<rehearsal external url>\nSECRET_KEY_BASE=' > /tmp/rehearsal.env && pbpaste >> /tmp/rehearsal.env && echo >> /tmp/rehearsal.env && pbcopy < /dev/null && echo "written $(wc -l < /tmp/rehearsal.env) lines"
   ```

4. Run the migrations and keep the log:

   ```sh
   docker run --rm --env-file /tmp/rehearsal.env esigncenter-release bundle exec rake db:migrate 2>&1 | tee /tmp/rehearsal-migrate.log
   ```

   Expect: every pending migration listed as migrated, and for the Session 1
   set the line `removing 0 over-copied account_configs row(s)`. Any error
   here stops the deploy.

5. Verify the rehearsed database looks right:

   ```sh
   docker run --rm --env-file /tmp/rehearsal.env esigncenter-release bundle exec rails runner '
     puts "customer-kind accounts (expect 0): #{Account.where(account_kind: "customer").count}"
     puts "accounts without a cert row (expect only testing children): " + Account.where.not(id: EncryptedConfig.where(key: "esign_certs").select(:account_id)).pluck(:id, :account_kind).inspect
     puts "smtp/timeserver rows: " + EncryptedConfig.where(key: %w[action_mailer_smtp timestamp_server_url]).pluck(:account_id, :key).inspect
   '
   ```

6. Delete `/tmp/rehearsal.env` (`rm /tmp/rehearsal.env`) and the
   `esigncenter-rehearsal` database.

### 2.4 Deploy dark

1. Confirm `REGISTRATION_ENABLED` and `BILLING_ENABLED` are unset (or
   `false`) on Render. New code goes live, but sign-up and billing stay
   invisible.
2. Confirm every variable in section 3 marked **Required** is set. In
   particular for Session 2: `SENTRY_DSN`, `OPERATOR_EMAIL`,
   `OPERATOR_PASSWORD` (only needed for the one-off seed; can be removed
   afterwards).
3. **Freeze provisioning for the deploy window.** Provisioning is how your
   own apps create EsignCenter workspaces (`POST /api/admin/accounts`).
   Until the new image is fully live, an account created by the *old* image
   would get the database default kind `customer` instead of `internal`.
   The freeze is procedural: nobody creates a workspace from an integrating
   app between "push" and the assertion in 2.5. If you need a hard freeze,
   temporarily change `ADMIN_PROVISION_TOKEN` on Render before the push and
   restore it after 2.5 (note: each env change restarts the service).
4. Push `master` (Render rebuilds). Watch the deploy log for the migration
   lines from 2.3. If the deploy fails health checks, Render keeps the old
   image serving — see rollback in 2.8.
5. When the deploy is live, open `https://<your host>/up` — it must return
   `"status":"ok"` with `"db":"ok"` and `"redis":"ok"` (section 4).

### 2.5 Provisioning-window assertion

From the Render Shell (this is the guard for the race described in 2.4):

```sh
bundle exec rails runner 'raise "customer-kind accounts exist: #{Account.where(account_kind: "customer").pluck(:id, :name).inspect}" unless Account.where(account_kind: "customer").none?; puts "ok: no customer-kind accounts"'
```

If it raises, the listed accounts were created by the old image during the
window. Registration is off, so they can only have come from your own apps —
re-classify them and re-run the assertion:

```sh
bundle exec rails runner 'Account.where(account_kind: "customer").find_each { |a| a.update!(account_kind: "internal"); puts "account #{a.id} -> internal" }'
```

Then lift the provisioning freeze.

### 2.6 Internal-account canary

Use one of your own apps' EsignCenter workspaces (an *internal* account).

1. **API send.** From the integrating app (or directly with that account's
   API token), send a document to yourself. Directly:

   ```sh
   curl -sS -X POST "https://<your host>/api/submissions" \
     -H "X-Auth-Token: <internal account api token>" -H "Content-Type: application/json" \
     -d '{"template_id": <template id>, "send_email": true, "submitters": [{"role": "First Party", "email": "you@example.com"}]}'
   ```

   (`role` must match a role name in that template.) Expect JSON with a
   submission id, and the invite email arriving from that app's own pinned
   mail server (not the platform default).
2. **Old-header webhook verify.** In the integrating app's logs, confirm the
   `form.started` / `submission.created` webhook arrived and its signature
   verified using the header the app reads — `X-Docuseal-Signature` (the same
   value is also sent as `X-Esigncenter-Signature`). A silent "webhook not
   authenticated" here means the fork was deployed after the app instead of
   before; fix the order and re-send.
3. **Signer completion.** Open the invite, sign, complete. Expect: the
   completion email, the signed PDF and audit log downloadable, and the
   `form.completed` / `submission.completed` webhook verified in the app.
4. **Post-deploy checks** in the Render Shell:

   ```sh
   bundle exec rails runner '
     puts "AccountLinkedAccount non-testing links to account 1 (expect true): #{AccountLinkedAccount.where(linked_account_id: 1).where.not(account_type: "testing").none?}"
     puts "smtp/timeserver rows: " + EncryptedConfig.where(key: %w[action_mailer_smtp timestamp_server_url]).pluck(:account_id, :key).inspect
   '
   ```

   Compare the second line with the 2.2 snapshot — the rows must be the same
   or a superset (the backfill adds, never removes).
5. Confirm no `no SMTP config for account` lines in the Render log and no new
   Sentry issues from the canary.
6. If this is the first deploy with Session 2 code, also run the one-off
   operator tasks in section 7.

### 2.7 Flip the switches (launch only)

Only after every launch gate in the plan is green. On Render set
`REGISTRATION_ENABLED=true` (and `BILLING_ENABLED=true` when billing is
ready). The service restarts. Re-open `/up` and repeat 2.6 step 1.

### 2.8 Rollback

**Rollback = flip the switches off.** Set `REGISTRATION_ENABLED` and
`BILLING_ENABLED` back to unset. Customers can no longer sign up or pay; the
code stays deployed. Do this when any of the following is true:

- `/up` reports `degraded` for more than a few minutes after the deploy
  finished.
- The canary in 2.6 fails at any step.
- Sentry shows a new error appearing on every request or every job run.
- Mail is not arriving from the canary within 5 minutes.

Escalation, in order:

1. Switches off (above). No data is lost.
2. Redeploy the previous commit from Render's deploy history ("rollback to
   this deploy"). Safe for code; the Session 1/2 migrations are one-way, but
   the old code tolerates the added columns and tables.
3. Database restore from the 2.2 snapshot (section 1.3) — **only** if data
   was corrupted, because anything signed after the snapshot is lost. Files
   in S3 are unaffected either way.

---

## 3. Environment variable manifest

One table, every variable the app reads that matters for production. "Where
read" names the file so an engineer can confirm behaviour. Variables from
`docs/render-deploy-checklist.md` "Session 1 additions" are folded in here.

Variables you will see in the local `.env` file but that **no code reads
yet** (Stripe, Turnstile, Google/Apple OAuth, Postmark stream ids) arrive in
Sessions 5–6 and are listed there when they land.

| Variable | Required? | Where it is read | What happens when missing |
| --- | --- | --- | --- |
| `DATABASE_URL` | Required | `config/dotenv.rb`, database config | Boot fails (production has no fallback). Use the database's **Internal** URL. |
| `SECRET_KEY_BASE` | Required | Rails sessions; `config/environments/production.rb` derives the **encryption key** for `encrypted_configs` (certificates, SMTP pins) from it; `config/dotenv.rb` and `lib/puma/plugin/redis_server.rb` derive the embedded Redis password from it | **Boot does not fail — it quietly makes a new one.** when no persisted `docuseal.env` exists yet, `config/dotenv.rb` generates a random secret, writes it to `<WORKDIR>/docuseal.env` and carries on. New sign-ins still work but every existing signed-in session is invalidated (everyone is logged out) and `/up` still says `ok`, but every existing encrypted row (signing certificates, pinned SMTP passwords) is unreadable under the new key: signing and tenant mail break with decryption errors. Render **must keep this variable set** on the service, and it must **never change** — keep an offline copy. |
| `ENCRYPTION_SECRET` | Optional | `config/environments/production.rb` | Derived from `SECRET_KEY_BASE`. Do not set it on an existing deployment; setting it later has the same effect as rotating the key. |
| `HOST` | Required unless `APP_URL` set | `lib/docuseal.rb` `default_url_options` only — it is the default source for generated links (webhooks, file URLs, and emails unless `EMAIL_HOST` is set — `EMAIL_HOST` overrides the host in email links, so update or unset it when the hostname changes). It is **not** fed into any Rails host allow-list; the app has none. | Links fall back to `http://localhost:3000` — every email and webhook link breaks. A value with a port (`host:3015`) is honoured. |
| `FORCE_SSL` | Required (`true`) | `lib/docuseal.rb` (links become `https`), production SSL redirect | Links are built with `http://` and the app does not force HTTPS. |
| `APP_URL` | Optional | `lib/docuseal.rb` `default_url_options` | When set, the full URL (`https://esign.example.com`) wins over `HOST`/`FORCE_SSL` for every generated link. When unset, `HOST` + `FORCE_SSL` are used. This is now the **only** source; the old per-account app-URL setting in the database is gone (see section 7). |
| `WORKDIR` | Set by the image (`/data/docuseal`) | `config/dotenv.rb`, Redis snapshot dir | Leave as the image sets it. |
| `ADMIN_PROVISION_TOKEN` | Required for provisioning | `app/controllers/api/admin/accounts_controller.rb` | Provisioning calls are refused. A `dev_prov_` value is refused in production. |
| `S3_ATTACHMENTS_BUCKET` | Required | `config/environments/production.rb`, `config/storage.yml`, `lib/storage_config_guard.rb` | Files silently go to the container's disk, which is wiped on every deploy. **This is the on/off switch for S3.** Since Session 2, a production boot with no storage variable set but an old storage-settings row in the database reports a warning to Sentry (it still boots). |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | Required with S3 | `config/storage.yml` | Uploads fail with credential errors. `AWS_REGION` defaults to `us-east-1`. |
| `S3_ENDPOINT` | Optional | `config/storage.yml` | Only for S3-compatible providers (Cloudflare R2). Unset for AWS. |
| `SMTP_ADDRESS` | Required for platform mail | `lib/mail_configs.rb`, `config/initializers/email_delivery.rb` | Accounts without their own pinned server send **nothing**: the message is dropped by a null delivery and an error `no SMTP config for account <id>` is reported to Sentry (Session 2 made this an error, not a warning). Internal accounts pinned via `email:pin` are unaffected. |
| `SMTP_PORT` | Optional | `lib/mail_configs.rb` | Defaults to `587`. |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | Required with `SMTP_ADDRESS` | `lib/mail_configs.rb` | Falls back to `POSTMARK_API_TOKEN` (below). If all three are blank, the platform SMTP connection is unauthenticated (boot warning). For Postmark, the EsignCenter server token goes in both. |
| `POSTMARK_API_TOKEN` | Optional | `lib/mail_configs.rb` `build_env_smtp` | Fallback for **both** `SMTP_USERNAME` and `SMTP_PASSWORD` when those are blank. Set either this or the pair, not both. |
| `SMTP_FROM` | Required with `SMTP_ADDRESS` | `lib/mail_configs.rb`, `config/initializers/email_delivery.rb` | **Boot refuses to start** in production when `SMTP_ADDRESS` is set and this is not — otherwise platform mail would go out under a tenant's From address. Format: `EsignCenter <noreply@esigncenter.com>`. |
| `SMTP_DOMAIN`, `SMTP_AUTHENTICATION`, `SMTP_ENABLE_STARTTLS`, `SMTP_ENABLE_SSL`, `SMTP_ENABLE_TLS`, `SMTP_SSL_VERIFY`, `SMTP_OPEN_TIMEOUT`, `SMTP_READ_TIMEOUT` | Optional | `lib/mail_configs.rb` | Tuning for non-Postmark servers. Defaults: STARTTLS on, certificate verification on, 15 s open / 25 s read timeouts. Leave unset for Postmark. |
| `EMAIL_DELIVERY_MODE` | Optional | `lib/mail_configs.rb`, `config/initializers/email_delivery.rb` | Defaults to `smtp` in production and `test` elsewhere. Set only to force one of those; any other value refuses to boot in production. In `test` mode no mail leaves the server. |
| `TIMESERVER_URL` | **Required** | `lib/docuseal.rb`, `lib/accounts.rb`, `config/initializers/timestamp_server_guard.rb` | The trusted timestamp authority (the DigiCert URL chosen in Session 0) stamped into every signed PDF. **Boot refuses to start** in production when it is unset. If the authority is unreachable at signing time the signing job **fails loudly** — Sentry gets one report and Sidekiq retries the job — instead of embedding a locally generated time that only looked trusted (section 8). |
| `REDIS_URL` | Optional today; required for managed Redis | `config/dotenv.rb`, `lib/rate_limit.rb`, Sidekiq | When unset the app derives a local URL and starts its own Redis inside the container (`lib/puma/plugin/redis_server.rb`). Setting it to a managed Redis URL turns the embedded one off automatically. See section 5. |
| `SIDEKIQ_THREADS` | Optional | `lib/puma/plugin/sidekiq_embed.rb` | Background-job worker threads; default 5. |
| `RUN_MIGRATIONS` | Optional | `config/initializers/migrate.rb` | Migrations run on every production boot unless set to `false`. Leave unset on Render; use `false` only for one-off consoles against a copy. |
| `SENTRY_DSN` | Required (Session 2) | `config/initializers/sentry.rb` | Sentry (error tracking) is not initialised; everything reported through `ErrorReport` — application errors, mail failures, rate-limit store (Redis) errors, the storage boot warning — goes to the Render log only. Nothing breaks, but nobody is alerted. |
| `SENTRY_ENVIRONMENT` | Optional | `config/initializers/sentry.rb` | Defaults to the Rails environment (`production`). Set to `staging` on a staging service so its errors are filed separately. |
| `OPERATOR_EMAIL` | Required for `rake operator:seed` only | `lib/tasks/operator.rake` | The task aborts with `OPERATOR_EMAIL is required`. |
| `OPERATOR_PASSWORD` | **Required** for `rake operator:seed` (Session 2 change) | `lib/tasks/operator.rake` | The task aborts with `OPERATOR_PASSWORD is required`. It is never generated or printed. Remove the variable from Render after the seed. |
| `SIDEKIQ_BASIC_AUTH_PASSWORD` | Optional | `config/initializers/sidekiq.rb` | Adds a browser username/password prompt in front of `/jobs` **in addition to** the operator + 2FA requirement. Not needed; the route already returns 404 to everyone else. |
| `REGISTRATION_ENABLED` | Launch switch | `lib/docuseal.rb`, `app/controllers/concerns/launch_gates.rb` | Unset = off: sign-up and confirmation pages return 404. Set exactly `true` to open. |
| `BILLING_ENABLED` | Launch switch | `lib/docuseal.rb`, `app/controllers/concerns/launch_gates.rb` | Unset = off: billing pages return 404. Set exactly `true` to open. |
| `CERTS` | **Gone (Session 4)** | — | The app no longer reads this variable anywhere; a leftover value on the service is inert. Signing identities come from the platform certificate on the operator account (section 8). A code gate fails the build if anything reads `CERTS` again. |
| `MULTITENANT` | **Must stay unset** | `lib/docuseal.rb`, `config/puma.rb` | Setting it changes tenancy behaviour and stops the embedded Redis/Sidekiq from starting. |
| `DEMO` | Must stay unset | `lib/docuseal.rb`, mail interceptor | Demo mode captures all mail and adds a demo queue. |
| `ACTIVE_STORAGE_PUBLIC` | Leave unset | `config/environments/production.rb`, `lib/docuseal.rb` | Unset = files are served through the app with expiring links (correct). `true` would assume a public bucket. |
| `PRESIGNED_URLS_EXPIRE_MINUTES`, `FILE_URLS_EXPIRE_MINUTES` | Optional | `config/environments/production.rb`, `lib/accounts.rb` | Download-link lifetimes; defaults 240 and 40 minutes. |
| `TRUSTED_CERTS` | Optional | `lib/docuseal.rb` | Extra root certificates trusted when verifying a signed PDF, on top of the platform certificate. Unset is fine. |
| `WORD_CONVERSION_ENABLED` | Optional (Session 4) | `lib/word_converter.rb` | Unset = Word (.docx/.doc) uploads are on whenever LibreOffice is in the image. Set to exactly `false` to switch them off: the upload forms stop offering Word files and any Word file sent is refused with a clear message. The kill switch for LibreOffice trouble. See `docs/word-uploads.md`. |
| `SOFFICE_PATH` | Optional (Session 4) | `lib/word_converter.rb` | Full path to the LibreOffice binary when `soffice` is not on `PATH`. Leave unset for the shipped image. |
| One-off, for `rake email:pin`: `ACCOUNT_ID`, `SMTP_TOKEN_ENV`, `FROM_EMAIL`, `SMTP_HOST`, `SMTP_PIN_PORT`, plus one variable per internal app holding that app's Postmark server token (any name; `SMTP_TOKEN_ENV` names it) | Task-time only | `lib/tasks/email.rake` | The task aborts naming the missing one. `SMTP_HOST` defaults to `smtp.postmarkapp.com`, `SMTP_PIN_PORT` to `587`. |

---

## 4. Health check and scheduler heartbeat

`GET https://<your host>/up` is the health check. It needs no login, sets no
cookies, and reveals nothing about accounts. Point Render's health check path
at `/up` (verify in the service settings).

It returns JSON:

```json
{
  "status": "ok",
  "db": "ok",
  "redis": "ok",
  "scheduler_last_tick_at": "2026-09-01T18:42:03Z"
}
```

How to read it:

| Field | Meaning | Action when bad |
| --- | --- | --- |
| `status` | `ok` (HTTP 200) when both `db` and `redis` are `ok`; otherwise `degraded` (HTTP 503) | Render treats 503 as unhealthy and will restart the instance / fail the deploy. That is intended: a build whose database or Redis is unreachable must not go live. |
| `db` | The app ran `SELECT 1` against PostgreSQL | `error` → check the database in the Render dashboard and `DATABASE_URL`. |
| `redis` | The app sent `PING` to Redis | `error` → embedded Redis died or a managed `REDIS_URL` is wrong. Background jobs and rate limits are down. Restart the service; check the Render log for `Unable to connect to redis`. |
| `scheduler_last_tick_at` | When the scheduler last fired. A tiny job (`SchedulerHeartbeatJob`) runs every minute on the `recurrent` queue and writes the time to Redis key `esigncenter:scheduler:last_tick_at`. | Informational only — it never flips `status`. |

**Reading the heartbeat.** The timestamp should be under 2 minutes old.
`null` right after a deploy is normal (Redis starts empty and the first tick
takes up to a minute). A timestamp **more than ~5 minutes old** while `redis`
is `ok` means jobs are not being processed: the embedded Sidekiq worker
inside the web container is not running or is stuck. Nothing time-based
(reminder emails, expirations, webhook retries, and later the billing jobs)
is happening. Restart the service; if it recurs, check `/jobs` (section 7)
for a stuck queue and Sentry for job errors.

The **scheduler** is `sidekiq-cron`: a list of jobs and their timings in
`config/schedule.yml`, loaded into Redis when Sidekiq starts. Today it holds
only the heartbeat; Session 7+ add suspension, dunning and purge jobs to the
same file.

---

## 5. Redis: embedded vs managed

**Decision deferred to launch-gate 3.** This section is the analysis that
decision is made from.

### What lives in Redis today

| Thing | What it is | Lifetime |
| --- | --- | --- |
| Job queues (`default`, `webhooks`, `sms`, `images`, `mailers`, `recurrent`) | Work waiting to run: send this email, deliver this webhook, generate this PDF | Seconds to minutes normally |
| The retry set | Jobs that failed and are waiting to try again (webhook retries back off 2, 4, 8… minutes; up to 13 attempts) | Minutes to hours |
| The scheduled set | Jobs booked for a **future time**: reminder emails (`SendSubmitterInvitationReminderEmailJob.perform_at`), submission expiry (`ProcessSubmissionExpiredJob.perform_at expire_at`), delayed invitation sends | Hours to **weeks** |
| Rate-limit windows | "This signer asked for a code 2 times in the last 45 s" — namespace `rate_limit`, TTLs 45 s to 5 min | Under 5 minutes |
| Cron schedule + heartbeat | The `sidekiq-cron` job list and `esigncenter:scheduler:last_tick_at` | Re-created at boot |

Redis's memory footprint for all of this is tiny (kilobytes to a few
megabytes). The concern is not size; it is **durability** and **coupling**.

### What is lost on a container restart or deploy

The embedded Redis runs as a child process of the web server and snapshots to
`/data/docuseal` inside the container. On Render the container filesystem
does not survive a deploy, and a restart gets a fresh container too (whether
an in-place restart keeps the snapshot file: **confirm at launch-gate
review**). So today, **every deploy silently empties Redis**:

- Queued jobs not yet started: lost. An email that was about to send never
  sends.
- Pending retries: lost. A webhook whose first delivery failed is never
  retried — the integrating app's periodic re-check is the only safety net.
- **Scheduled future jobs: lost.** A reminder booked for Thursday, an
  expiry booked for next month — gone if a deploy happens in between. This
  is the serious one, and it is already true in production today.
- Rate-limit windows: reset. Harmless (a signer can ask for one extra code).
- Heartbeat: `null` until the first tick after boot. Harmless.

### What happens while Redis is unreachable

The rate limiter **fails open**. If Redis cannot be reached (it crashed, or
a managed `REDIS_URL` is wrong), every rate limit in the app is simply off
until it comes back — the 2FA code sends, the API creation limits, the
"reveal API token" limit (Rails' own `rate_limit`, which shares the same
store), all of them. Nothing errors for the user; requests go through. Two
side effects to know about:

- Each request that would have been rate-limited waits for the Redis
  connection to time out first, so those requests get roughly **one extra
  second** of latency while Redis is down.
- Every failed store call is reported through `ErrorReport` (the app's one
  reporting seam) at warning level — to Sentry when `SENTRY_DSN` is set, to
  the log otherwise — so a Redis outage shows up in Sentry as a stream of
  rate-limit store errors (`Redis::CannotConnectError` and friends). That is
  the signal to look at; the app itself will not tell you its limits are
  off.

This is a deliberate choice: an unreachable Redis should not turn every
signing link into a "Too many requests" page. The trade-off is that the
limits are only as available as Redis is — one more argument for the managed
option above.

Also: if Redis dies for any reason, the Puma plugin **kills the web server
with it** (`lib/puma/plugin/redis_server.rb` sends INT to Puma), so a Redis
crash is a full outage until Render restarts the container.

### Memory contention with LibreOffice (Session 4)

Session 4 adds Word-to-PDF conversion using LibreOffice, running as a
background job **inside the same container** as Puma, Sidekiq and the
embedded Redis. LibreOffice can spike to hundreds of megabytes per
conversion. If the container hits its memory limit, the whole container is
killed — and with it every queued, retrying and scheduled job in the embedded
Redis. Session 4's guards (two-slot conversion cap, hard timeout, size cap)
reduce the odds; they do not change what is lost when it happens. The
Render plan's memory limit for the Standard tier: **confirm at launch-gate
review** (the checklist notes the PDF work already needs Standard).

What shipped (Session 4 D): conversions run on the `documents` Sidekiq queue
(a fetch weight on the shared worker pool, not a thread of its own), at most
**two** LibreOffice processes at once — the two-slot counter
(`WordConverter::MAX_CONCURRENT`) is the real cap, and it fails closed when
Redis cannot answer — a 120-second hard timeout that kills the
whole process group, a 20 MB file cap, and 30 conversions per account per
hour. Budget a few hundred megabytes per running conversion on top of the
web server's working set when choosing the tier. `WORD_CONVERSION_ENABLED=false`
turns the feature off without a deploy. Details in `docs/word-uploads.md`.

### Cost of Render managed Redis

Render's managed Redis product is called **Key Value**. What matters here:
the free tier does not persist data to disk (so it would buy nothing over
embedded), while paid tiers do. Tier names, memory sizes and monthly prices
change — **confirm current pricing in the Render dashboard at launch-gate
review**; expect the smallest persistent tier to be in the low tens of
dollars per month. Switching is one environment variable: set `REDIS_URL` to
the Key Value instance's internal URL and the embedded Redis stops starting
(the plugin only runs when the app had to invent a local URL). No code
changes.

### Recommendation

**Move to managed (persistent) Redis before flipping `REGISTRATION_ENABLED`;
stay embedded until then.** Reasoning:

- While the only users are your own apps, a lost reminder or retry is a
  tolerable, known cost — the apps re-check on a schedule.
- A paying customer cannot be told "your reminder didn't go out because we
  deployed on Tuesday". Deploys will be frequent early on, and the scheduled
  set is exactly the thing that makes a deploy customer-visible.
- Managed Redis also decouples the queue from a LibreOffice memory spike: a
  killed container loses only the job running at that instant, not
  everything waiting.
- The trade-off is money (a monthly line item, amount to confirm) plus one
  more service to watch, against a small network hop per job. Sidekiq's
  default job-fetch means a job *in progress* when a worker dies is still
  lost even with managed Redis; only queued/scheduled/retrying work becomes
  safe.

The alternative worth stating: keep embedded Redis **and** make every
time-based action re-derivable from the database by a cron sweep (reminders,
expiry, dunning read "what is due now" from PostgreSQL each run). Session 10's
retention layer moves in that direction. If that pattern covers everything
scheduled, Redis becomes a purely transient work queue and embedded is
defensible. That is a design choice for the launch-gate review, not for this
document.

---

## 6. Postmark: moving to a separate account

Decision D62: EsignCenter customer mail currently goes through the
**EsignCenter server on Evan's shared Postmark account**, alongside the
servers for your other apps. Postmark suspends compliance problems at the
*account* level, so a burst of abuse from free EsignCenter signups could
pause your other apps' email too. The named remedy — moving customer traffic
to its own Postmark account — is triggered by traction or the first abuse
incident, whichever comes first. About one hour of work; nothing in the code
changes.

Internal apps are **not** affected: they are pinned to their own servers on
the old account via `rake email:pin`, and those pins are rows in the
database that this migration does not touch.

1. **Create the new Postmark account** (a new login, or a second account
   under the same login if Postmark offers that — verify in the dashboard).
   Complete its sender approval questionnaire; new accounts start in a test
   mode limited to your own domain until approved.
2. **Add `esigncenter.com` as a sender domain** in the new account.
   Postmark shows a DKIM TXT record and a Return-Path CNAME. (DKIM is the
   signature that proves mail really came from you; Return-Path handles
   bounces.) The DKIM record for the new account has a **different selector
   name** from the old one, so both can coexist.
3. **Add both DNS records at Namecheap** (Advanced DNS for
   `esigncenter.com`). Leave the old DKIM record in place until step 8.
   Keep the existing `_dmarc` TXT record unchanged.
4. **Wait for Verified** on both records in Postmark (minutes to an hour).
5. **Create the server** — name it `EsignCenter` — and inside it re-create
   the message streams you use today: the default transactional stream plus
   the separate `free` and `paid` streams (match the stream ids the app is
   configured with, or note the new ids for the env vars that select streams
   by plan when Session 5 lands). Copy the new server's API token.
6. **Re-point complaint/bounce webhooks** (launch gate 4) on the new server
   to the same URLs, with the same basic-auth credentials.
7. **Rotate the credentials on Render**: set `SMTP_USERNAME` and
   `SMTP_PASSWORD` to the new server token (or `POSTMARK_API_TOKEN` if that
   is what is set). Hand the token over via the clipboard, never in chat.
   The service restarts. Then run the canary (section 2.6 step 1) from a
   **non-pinned** account — the operator account or a test customer account —
   and confirm in the new Postmark server's Activity that the message went
   through it, with DKIM shown as passing.
8. **Decommission**: after a week with no traffic on the old EsignCenter
   server (check its Activity), delete that server on the old account and
   remove the old DKIM TXT record at Namecheap. The old account's other
   servers (your other apps) stay exactly as they are.

Rollback at any point before step 8: put the old server token back in the
Render env vars.

---

## 7. What Session 2 changed for operators

- **Operator seed requires a password and prints nothing secret.**
  `rake operator:seed` now aborts unless both `OPERATOR_EMAIL` and
  `OPERATOR_PASSWORD` are set; it no longer generates or prints a password
  (the old behaviour put it in the deploy log). Set `OPERATOR_EMAIL` and
  `OPERATOR_PASSWORD` as env vars on the Render service (the service
  restarts), then run once from the Render Shell:

  ```sh
  bundle exec rake operator:seed
  ```

  Expect `Created operator account <id>.` Then remove both variables from
  the service. Safe to re-run: it says an operator account already exists
  and stops.
- **Then enrol 2FA for that operator user** (log in → Settings → two-factor
  setup at `/mfa_setup`). Operator surfaces require **both** the operator
  flag and 2FA; the flag alone does nothing.
- **`/jobs` (the Sidekiq console — live view of the job queues) needs the
  operator flag + 2FA.** Everyone else — anonymous, customer admins,
  internal-app admins, and even an admin inside the operator account's
  test-mode twin — gets a plain 404, not a redirect. There is no HTTP path
  that grants the operator flag: only the rake task can set it, and a golden
  spec asserts that.
- **The full-text search toggle (`POST /settings/search_entries_reindex`) is
  operator-only** and stores its flag on the operator account, never on
  "account #1". Non-operators get 404 and do not see the button.
- **Full-text search is off on a fresh install until an operator turns it
  on.** The setup wizard no longer switches it on. Search and autocomplete
  still work (they fall back to plain database matching); they just get slow
  on large accounts. To turn it on: log in as the operator → Settings →
  **Build search index**. On an **upgrade** of the existing production
  database nothing is lost: `rake operator:seed` notices the old global
  flag (it lived on the lowest-id account) and copies it onto the new
  operator account, printing `fulltext search flag adopted from legacy
  account <id>`. The old row is left where it was. Run the seed before
  anyone searches, or search runs in the slow mode until you do.
- **The "Send copy of documents" email button is now rate-limited**: a
  signer can ask for a copy of their signed documents at most **2 times per
  5 minutes**; a third click shows "Too many requests". That limit was
  always in the code but was switched off in this deployment until Session
  2 turned the limiter on everywhere. The limit values themselves did not
  change.
- **Old app-URL rows are inert and can be ignored.** Links come from
  `APP_URL`, else `HOST` + `FORCE_SSL`, else `http://localhost:3000`. The
  setup wizard and account settings no longer show a URL field, and saving
  account settings no longer fails for accounts that never had that row.
  Any `app_url` rows still in `encrypted_configs` are harmless leftovers; no
  migration deletes them.
- **Rate limits now live in Redis** and are on in every environment (the
  test suite uses an in-memory store). Limit values are unchanged. They
  reset on a Redis restart (section 5).
- **Per-account counters never reset on deletion.** The new
  `account_counters` table keeps durable monthly counts (`submissions_created`
  is the first). Deleting the documents does not lower the count; deleting the
  account removes its rows. Nothing reads them yet — Session 5's quotas will.
- **Sentry replaces Rollbar.** Set `SENTRY_DSN`; there are no Rollbar
  references left in the code. Mail delivery failures now reach Sentry (SMTP
  errors raise inside the mail job and retry), and an account with no mail
  server at all is an **error** in Sentry, not a log warning. Rails' own
  error reporter is subscribed to Sentry as well, so framework-internal
  reports land there too. One thing is **not** covered any more: JavaScript
  errors in the signer's browser (the signing page) were captured by
  Rollbar's browser SDK and are no longer captured by anything — add
  `@sentry/browser` later if that visibility is wanted.
- **Mail is never silently hoarded.** Outside the test suite, "no server" and
  `EMAIL_DELIVERY_MODE=test` use a true null delivery that discards the
  message instead of keeping it in memory forever.
- **`/up` is the health check** (section 4) — JSON with database, Redis and
  scheduler status; point Render at it.
- **Boot warns if storage silently fell back to disk.** If the database still
  holds an old storage-settings row but no `S3_ATTACHMENTS_BUCKET` (or GCS /
  Azure) variable is set, boot reports a warning to Sentry and the log. It
  never refuses to start.
- **A scheduler exists** (`sidekiq-cron`, `config/schedule.yml`) with one
  heartbeat job; future recurring jobs are added to that file.
- **API tokens are checked against account state at request time.** An
  archived account's still-valid API token or MCP key gets
  `401 {"error": "Account is not active"}`; an embedded template-builder
  token (minted through the API) gets a plain 404. Session 7 adds suspension
  to the same guard (`lib/account_states.rb`).

---

## 8. Signing certificates and timestamps

*(Session 4. Plain English: a **certificate** is the digital identity a PDF
signature is made with — like a company seal. A **timestamp authority (TSA)**
is an outside service that vouches for what time the signature was made.)*

### 8.1 One platform certificate for every customer

Every customer account signs with **one** certificate — the platform
certificate, named `EsignCenter` — held by the platform-operator account. A
customer account can no longer have a signing identity of its own: if an old
certificate row is still sitting on a customer account (every account got one
from the Session 1 upgrade), it is **ignored**.

- **Where it lives:** an encrypted row (`platform_esign_certs`) on the
  operator account. There is exactly one.
- **Where it comes from:** `rake operator:seed` creates it the first time it
  runs, and the task is safe to re-run — it never makes a second one.
- **Internal apps (VA Claims and friends) are the exception:** they keep
  their own certificate rows and keep signing with them. Those rows are no
  longer editable in the app; changing one is a console job (Session 8 adds
  an operator console for it).
- **No operator account = no signing.** If the platform certificate cannot be
  resolved, signing stops with a loud error naming `rake operator:seed`
  instead of quietly borrowing some other account's identity.

### 8.2 Custody: keep an offline copy (launch gate 1)

The platform certificate is the only thing that proves an EsignCenter
signature is ours. Losing the database without a copy means every document
signed so far can no longer be traced to a certificate you still hold. Export
it once, right after the seed, and keep it somewhere safe and offline (a
password manager's secure file store, or an encrypted USB stick):

```sh
bundle exec rake "operator:platform_cert:export[/tmp/esigncenter-platform-cert.pem]"
```

It writes one file readable only by its owner (mode `0600`) holding the
certificate, its two authority certificates and the private keys, and prints
**only** the fingerprint and the file size — never any key material. Download
it from the Render Shell, store it, then delete the copy in `/tmp`.

To check at any time which certificate the running app is using:

```sh
bundle exec rake operator:platform_cert:fingerprint
```

Compare that fingerprint with the one printed by the export. If they differ,
the running app is signing with a certificate you do not have a copy of.

### 8.3 Restore and rotation

- **Restore:** the certificate comes back with the database (it is a row in
  `encrypted_configs`). The offline copy is the fallback for the case where
  the database is gone for good.
- **Rotation** (only if the key is believed exposed): in the Render Shell,
  delete the platform row and let the next signature generate a fresh one —

  ```sh
  bundle exec rails runner 'OperatorConfigs.account.encrypted_configs.find_by(key: EncryptedConfig::PLATFORM_ESIGN_CERTS_KEY)&.destroy!; puts PlatformCertificate.fingerprint'
  ```

  then **export the new one immediately**. Consequence: documents signed
  before the rotation stay valid and verifiable — the old certificate is
  still trusted for verification — but new signatures carry the new
  identity, and the two fingerprints differ. Never rotate casually.

### 8.4 The timestamp authority is loud now

`TIMESERVER_URL` is required in production; the app refuses to boot without
it. When the authority is unreachable or answers with an error, the signing
job now **fails**: Sentry gets one report, Sidekiq retries the job (a short
outage heals itself), and no document is written with a fake timestamp. The
old behaviour embedded a locally generated time that looked like a trusted
timestamp but proved nothing.

Customer accounts always use the platform `TIMESERVER_URL`; a timestamp-server
row on a customer account is ignored. Internal accounts may still pin their
own.

### 8.5 Certificates and timestamps are operator-only surfaces

In **Settings → E-Signature**, every admin still sees the signing
preferences (multiple signatures, flatten, download filename). The
certificate table, the certificate upload button, the timestamp-server form
and the PDF-verification box are visible **only** to the platform operator;
for everyone else those pages return 404, exactly as if the routes did not
exist.
