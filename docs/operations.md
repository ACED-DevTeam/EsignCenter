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

4. Prove both the internal-account signing key and the platform signing key
   decrypt — this is the step that fails if `SECRET_KEY_BASE` were ever lost:

   ```ruby
   cert = EncryptedConfig.where(key: 'esign_certs').order(:account_id).first
   puts cert.account_id, cert.value.keys.inspect   # expect the certificate field names, no error

   platform_fingerprint = PlatformCertificate.fingerprint
   puts platform_fingerprint   # expect the fingerprint recorded in the operations notes
   ```

   The platform fingerprint must exactly match the value recorded after
   `rake operator:platform_cert:fingerprint` during deployment. A mismatch or
   decryption error means the restore has not passed.

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

Sessions 4 to 7 added the rest. ★ marks one that changes or destroys data, or
that cannot be undone — the reason the rollback rule below exists.

| Migration | What it does |
| --- | --- |
| `20260902100000` | Creates `verified_documents` — the fingerprint of every PDF this app has signed, which the public `/verify` page answers from |
| ★ `20260902100100` | Backfills that table from every document already signed |
| `20260902120000` | Creates `account_subscriptions` (who is on which plan, and what Stripe says) |
| `20260902120100` | Creates `account_limit_overrides` (per-account limit overrides for the operator) |
| `20260902120200` | Creates `abuse_flags` (fair-use, velocity, complaint, bounce and reported-document rows) |
| `20260902120300` | Adds the sending-pause columns to accounts |
| ★ `20260902120400` | Turns the old plan placeholders into real subscription rows. Development and test hygiene only — production has no such rows |
| `20260903000100` | Creates `stripe_event_inboxes` (every Stripe event, recorded once, so a replay changes nothing) |
| `20260903000200` | Adds the Stripe state columns to `account_subscriptions` |
| `20260903010000` | Adds `submissions.resubmitted_from_id` |
| `20260903020000` | Adds `account_subscriptions.ended_at` |
| ★ `20260903020100` | Adds `submissions.lineage_root_id` and fills it in for every existing submission, one row at a time. Fine on today's data; **batch it before running against a large table** |
| `20260903030000` | Adds the suspension columns to accounts (the day-14 read-only freeze) |
| `20260904000100` | Creates `account_invites` (seat invitations) |
| `20260904000200` | Adds `users.read_only_at` (a person parked read-only by a downgrade) |
| `20260904000300` | Creates `account_moves` (the record of a person joining another team) |
| `20260904000400` | Adds the deletion columns to accounts (the 90-day window) |
| `20260904000500` | Adds `account_subscriptions.refund_owed` |
| `20260904010000` | Adds the dormant-warning columns to accounts |
| `20260904020000` | Adds the purge claim and the deletion confirmation code to accounts |
| `20260904030000` | Adds the deletion code's expiry/attempt window |
| ★ `20260904040000` | Puts a real foreign key on `webhook_attempts.webhook_event_id`, with "delete the event, delete its attempts". **Deletes orphaned attempt rows first** — count them on the rehearsal copy (section 2.3, step 4b) |
| ★ `20260904041500` | Adds `users.session_version`. **Every signed-in person is signed out of every browser on the day this ships** (humans only — API tokens and the integrating apps' credentials are untouched) |
| ★ `20260904050000` | Adds `accounts.last_active_at`. Existing rows stay empty on purpose, so no dormancy clock moves — but **any account part-way through a dormancy warning has that warning cleared and starts its notice again** |

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

4b. **Count the orphaned webhook attempts** (only matters the first time
   `20260904040000` runs — after that the foreign key makes orphans
   impossible). Run this against the **restored copy, before** the migration,
   from a `psql` shell on the rehearsal database:

   ```sql
   SELECT count(*) FROM webhook_attempts a
     LEFT JOIN webhook_events e ON e.id = a.webhook_event_id
    WHERE e.id IS NULL;
   ```

   These are delivery-attempt rows whose event has already been deleted —
   nothing in the app can reach them, and the migration **deletes them** (the
   foreign key cannot be created while they exist). What to do with the
   answer:

   - **Zero** — nothing to think about; the migration adds the key and moves on.
   - **A small number** — expected on an older database. Write the number in
     the deploy notes and carry on; they are unreachable rows holding a
     customer's webhook responses, which is exactly why they are being cleared.
   - **Large, or larger than you can explain** (say, a noticeable share of
     `SELECT count(*) FROM webhook_attempts`) — stop and find out why events
     are disappearing while their attempts survive before you deploy, because
     the same cause is probably still running. The rehearsal is a throwaway
     copy, so nothing has been lost yet; you have the snapshot either way.

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
yet** (Stripe, Apple OAuth) arrive in Sessions 6 and later and are listed
here when they land. Turnstile and Google OAuth landed with Session 5
(`docs/signup.md`).

| Variable | Required? | Where it is read | What happens when missing |
| --- | --- | --- | --- |
| `DATABASE_URL` | Required | `config/dotenv.rb`, database config | Boot fails (production has no fallback). Use the database's **Internal** URL. |
| `SECRET_KEY_BASE` | Required | Rails sessions; `config/environments/production.rb` derives the **encryption key** for `encrypted_configs` (certificates, SMTP pins) from it; `config/dotenv.rb` and `lib/puma/plugin/redis_server.rb` derive the embedded Redis password from it | **Boot does not fail — it quietly makes a new one.** when no persisted `docuseal.env` exists yet, `config/dotenv.rb` generates a random secret, writes it to `<WORKDIR>/docuseal.env` and carries on. New sign-ins still work but every existing signed-in session is invalidated (everyone is logged out) and `/up` still says `ok`, but every existing encrypted row (signing certificates, pinned SMTP passwords) is unreadable under the new key: signing and tenant mail break with decryption errors. Render **must keep this variable set** on the service, and it must **never change** — keep an offline copy. |
| `ENCRYPTION_SECRET` | Optional | `config/environments/production.rb` | Derived from `SECRET_KEY_BASE`. Do not set it on an existing deployment; setting it later has the same effect as rotating the key. |
| `SESSION_REMEMBER_DAYS` | Optional | `config/initializers/devise.rb` | How long a "remember me" cookie keeps somebody signed in. Unset = **730 days (two years)**, and sign-up turns remember-me on for everybody — which is why "unused" is measured from `accounts.last_active_at` (a real request) and not from the last sign-in (section 4.1 and `docs/account-deletion.md`). Shortening it makes people sign in more often; it changes nothing about dormancy. |
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
| `TIMESERVER_URL` | **Required** | `lib/docuseal.rb`, `lib/accounts.rb`, `config/initializers/timestamp_server_guard.rb` | The trusted timestamp authority (the DigiCert URL chosen in Session 0) stamped into every signed PDF; several URLs may be listed comma-separated and every one is tried in turn. **Boot refuses to start** in production when it is unset. If no authority answers at signing time the signing job **fails loudly** — the app reports it once and Sidekiq retries the job — instead of embedding a locally generated time that only looked trusted (section 8.4). |
| `REDIS_URL` | Optional today; required for managed Redis | `config/dotenv.rb`, `lib/rate_limit.rb`, Sidekiq | When unset the app derives a local URL and starts its own Redis inside the container (`lib/puma/plugin/redis_server.rb`). Setting it to a managed Redis URL turns the embedded one off automatically. See section 5. |
| `SIDEKIQ_THREADS` | Optional | `lib/puma/plugin/sidekiq_embed.rb` | Background-job worker threads; default 5. |
| `RUN_MIGRATIONS` | Optional | `config/initializers/migrate.rb` | Migrations run on every production boot unless set to `false`. Leave unset on Render; use `false` only for one-off consoles against a copy. |
| `SENTRY_DSN` | Required (Session 2) | `config/initializers/sentry.rb` | Sentry (error tracking) is not initialised; everything reported through `ErrorReport` — application errors, mail failures, rate-limit store (Redis) errors, the storage boot warning — goes to the Render log only. Nothing breaks, but nobody is alerted. |
| `SENTRY_ENVIRONMENT` | Optional | `config/initializers/sentry.rb` | Defaults to the Rails environment (`production`). Set to `staging` on a staging service so its errors are filed separately. |
| `OPERATOR_EMAIL` | Required for `rake operator:seed` only | `lib/tasks/operator.rake` | The task aborts with `OPERATOR_EMAIL is required`. |
| `OPERATOR_PASSWORD` | **Required** for `rake operator:seed` (Session 2 change) | `lib/tasks/operator.rake` | The task aborts with `OPERATOR_PASSWORD is required`. It is never generated or printed. Remove the variable from Render after the seed. |
| `SIDEKIQ_BASIC_AUTH_PASSWORD` | Optional | `config/initializers/sidekiq.rb` | Adds a browser username/password prompt in front of `/jobs` **in addition to** the operator + 2FA requirement. Not needed; the route already returns 404 to everyone else. |
| `REGISTRATION_ENABLED` | Launch switch | `lib/docuseal.rb`, `app/controllers/concerns/launch_gates.rb` | Unset = off: sign-up and confirmation pages return 404. Set exactly `true` to open. |
| `BILLING_ENABLED` | Launch switch | `lib/docuseal.rb`, `app/controllers/concerns/launch_gates.rb` | Unset = off: billing pages return 404. Set exactly `true` to open. **The Stripe webhook endpoint (`POST /stripe/webhooks`) stays open either way** — the switch decides what customers can reach, not whether Stripe may tell us a subscription changed. Losing those events would leave the app's idea of who is paying permanently wrong. See `docs/billing.md`. |
| `STRIPE_SECRET_KEY` | **Required when `BILLING_ENABLED=true`** (Session 6) | `lib/stripe_billing.rb`, `lib/stripe_billing/config_guard.rb` | The secret API key every Stripe call is made with. **Boot refuses to start** in production when billing is on and it is unset, malformed, or a **test** key (`sk_test_…`) — a test key in production would take real customers through a sandbox and never charge anyone. Read fresh on every call; never cached at boot. |
| `STRIPE_PUBLISHABLE_KEY` | **Required when `BILLING_ENABLED=true`** (Session 6) | `lib/stripe_billing.rb` | The public key (`pk_…`). Checked at boot for presence and shape. |
| `STRIPE_WEBHOOK_SECRET` | **Required when `BILLING_ENABLED=true`** (Session 6) | `lib/stripe_billing.rb`, `app/controllers/stripe_webhooks_controller.rb` | The signing secret (`whsec_…`) every incoming Stripe webhook is verified against. **While it is blank the webhook endpoint answers 503** rather than trusting an unverified body. From the Stripe dashboard's endpoint for production, or from `stripe listen` for the dev stack. |
| `STRIPE_PRICE_ID` | **Required when `BILLING_ENABLED=true`** (Session 6) | `lib/stripe_billing.rb`, billing checkout | The one price the product sells: $10 per seat per month (`price_…`). The server always uses this value — no request may name a price. `rake stripe:check` asserts the live price is still monthly, $10, USD and active. |
| `STRIPE_PORTAL_CONFIGURATION_ID` | **Required when `BILLING_ENABLED=true`** (Session 6) | `lib/stripe_billing.rb`, billing portal | The Customer Portal configuration (`bpc_…`) created by `rake stripe:portal_configuration`. It decides what a customer may change in Stripe: card, cancellation, invoices — **never** seats. |
| `TURNSTILE_SITE_KEY` | **Required when `REGISTRATION_ENABLED=true`** (Session 5) | `app/views/devise/registrations/new.html.erb`, `lib/registration_config_guard.rb` | The public key the sign-up page hands to Cloudflare's widget. **Boot refuses to start** in production when sign-up is on and this is unset. The dev stack uses Cloudflare's always-passing test key. |
| `TURNSTILE_SECRET_KEY` | **Required when `REGISTRATION_ENABLED=true`** (Session 5) | `lib/turnstile.rb`, `lib/registration_config_guard.rb` | The server-side key used to ask Cloudflare whether a sign-up token is genuine. **Boot refuses to start** in production when sign-up is on and this is unset; at runtime a blank key fails every email sign-up closed (*Please complete the verification*). Never bypassed by any environment setting. |
| `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` | Optional (Session 5) | `config/initializers/devise.rb`, `lib/registrations.rb`, `lib/registration_config_guard.rb` | The Google OAuth app behind **Continue with Google**. With either unset the button is hidden on the sign-in and sign-up pages and a warning is reported at boot; email sign-up works regardless. Until the Google app is published it runs in Testing mode and only its listed test users can use the button (launch gate 4b). |
| `POSTMARK_STREAM_PAID`, `POSTMARK_STREAM_FREE` | Optional (Session 5) | `lib/action_mailer_configs_interceptor.rb` (Phase D) | Postmark message-stream ids. When both are set, platform mail for free accounts goes out on the free stream and everything else (paid, internal, operator alerts) on the paid stream, so a spammy free tier cannot hurt paying customers' deliverability. Unset = no stream header, one shared stream. Accounts with their own pinned SMTP server never get the header. |
| `POSTMARK_WEBHOOK_USERNAME`, `POSTMARK_WEBHOOK_PASSWORD` | Required for delivery webhooks | `lib/postmark_webhooks.rb` | Choose credentials for the webhook URL. These are separate from the SMTP server token. If either is blank, the endpoint returns 503 and records nothing. Wrong or missing credentials return 401. |
| `POSTMARK_WEBHOOK_IPS` | Optional | `lib/postmark_webhooks.rb` | Comma-separated IP addresses or CIDR ranges allowed to call the webhook. Blank uses `3.134.147.250,50.31.156.6,50.31.156.77,18.217.206.57`. An address outside the list returns 403 even with correct credentials. |
| `CERTS` | **Gone (Session 4)** | — | The app no longer reads this variable anywhere; a leftover value on the service is inert. Signing identities come from the platform certificate on the operator account (section 8). A code gate fails the build if anything reads `CERTS` again. |
| `MULTITENANT` | **Must stay unset** | `lib/docuseal.rb`, `config/puma.rb` | Setting it changes tenancy behaviour and stops the embedded Redis/Sidekiq from starting. |
| `DEMO` | Must stay unset | `lib/docuseal.rb`, mail interceptor | Demo mode captures all mail and adds a demo queue. |
| `ACTIVE_STORAGE_PUBLIC` | Leave unset | `config/environments/production.rb`, `lib/docuseal.rb` | Unset = files are served through the app with expiring links (correct). `true` would assume a public bucket. |
| `PRESIGNED_URLS_EXPIRE_MINUTES`, `FILE_URLS_EXPIRE_MINUTES` | Optional | `config/environments/production.rb`, `lib/accounts.rb` | Download-link lifetimes; defaults 240 and 40 minutes. |
| `TRUSTED_CERTS` | Optional | `lib/docuseal.rb` | Extra root certificates trusted when verifying a signed PDF, on top of the platform certificate. Unset is fine. |
| `WORD_CONVERSION_ENABLED` | Optional (Session 4) | `lib/word_converter.rb` | Unset = Word (.docx/.doc) uploads are on whenever LibreOffice is in the image. Set to exactly `false` to switch them off: the upload forms stop offering Word files and any Word file sent is refused with a clear message. The kill switch for LibreOffice trouble. See `docs/word-uploads.md`. |
| `WORD_CONVERSION_SLOTS` | Optional (Session 4) | `lib/word_converter.rb` | How many Word conversions (LibreOffice processes) may run at once on the instance. Unset = `2`. A whole number, never below 1; anything else falls back to the default. Set to `1` if the launch-gate memory check (`docs/render-deploy-checklist.md`) shows two do not fit; takes effect at the next job. |
| `SOFFICE_PATH` | Optional (Session 4) | `lib/word_converter.rb` | Full path to the LibreOffice binary when `soffice` is not on `PATH`. Leave unset for the shipped image. |
| One-off, for `rake email:pin`: `ACCOUNT_ID`, `SMTP_TOKEN_ENV`, `FROM_EMAIL`, `SMTP_HOST`, `SMTP_PIN_PORT`, plus one variable per internal app holding that app's Postmark server token (any name; `SMTP_TOKEN_ENV` names it) | Task-time only | `lib/tasks/email.rake` | The task aborts naming the missing one. `SMTP_HOST` defaults to `smtp.postmarkapp.com`, `SMTP_PIN_PORT` to `587`. |
| One-off, for `rake accounts:purge`: `FORCE`, `CONFIRM` | Task-time only | `lib/tasks/accounts.rake` | Only needed to purge an account that is **not** due to be purged. Without `FORCE=1` the task refuses and changes nothing; with it, the task prints what the account still holds and then refuses again unless `CONFIRM` is the account's name typed back exactly. See section 4.2. |

---

### 3.1 Postmark message streams by plan

Platform mail carries an `X-PM-Message-Stream` header chosen by the sending
account's plan: free accounts go out on `POSTMARK_STREAM_FREE`, and paid,
internal and operator mail — including operator alerts and any mail with no
account behind it — on `POSTMARK_STREAM_PAID`. Postmark tracks reputation
per stream, so a burst of abuse from free sign-ups cannot drag down
delivery for paying customers. The header is only set when *both* variables
are present; with either missing every message uses the server's default
stream. Accounts pinned to their own SMTP server (`rake email:pin`) never
get the header — a pinned server is a different Postmark server with its own
streams. Proof: `spec/golden/postmark_stream_spec.rb`.

### 3.2 Operator alerts, reported documents and the abuse queue

Two things email the operator automatically (`lib/operator_alert.rb`): a
sending pause (docs/quotas-and-limits.md section 3) and a **reported
document** — every signing page carries a small "Report this document" link
to an anonymous form (`/report/<signer slug>`, four reasons plus free text,
limited to 5 reports per hour per network and 3 per signer link, so each
signer keeps their own budget). Each report
is an `abuse_flags` row of kind `document_report` on the sending account,
with the reason, details, reporter IP and browser, and the submission it
points at. The alert goes to the `operator_alert_email` operator config when
the Session 8 console has set one, else to the support mailbox
(`Docuseal::SUPPORT_EMAIL`), which is set on the console's **Platform
settings** tab. The console's **Abuse queue** tab
(`/operator/abuse`) is where these rows are worked: it lists every flag on
the platform next to the fair-use, velocity, complaint and bounce ones,
filters by kind and by account, and carries a badge in the console navigation
with the number still open.

Two buttons, and they are deliberately separate:

- **Resolve** closes the flag with your reason written onto the row. It
  changes nothing else — an account whose sending is paused stays paused.
- **Resume sending** lifts the automatic pause. That also resolves that
  account's open spam-complaint and bounce-rate flags, because those two
  flags ARE the pause; every other flag stays open for review.

A reported document shows the template, how many people were asked to sign,
the reason and free text the reporter gave, and the signing link **as text
rather than a link** — opening it would put you inside a signer's session.

### 3.3 Postmark delivery webhooks

1. Set `POSTMARK_WEBHOOK_USERNAME` and `POSTMARK_WEBHOOK_PASSWORD` on the
   EsignCenter service, using a new username and a long random password.
   Restart the service so it reads them. These are webhook credentials,
   separate from your Postmark SMTP token.
2. In Postmark, open **Servers → EsignCenter → Webhooks** (choose each
   outbound message stream if using separate free and paid streams).
   Add URL `https://<user>:<pass>@esigncenter.com/webhooks/postmark`, replacing
   the placeholders with those credentials. URL-encode any special characters.
3. Tick **Delivery**, **Bounce**, **Spam complaint** and **Open**; leave
   **Subscription change** on. Do not enable Postmark click tracking: the app
   already records clicks through its own signature-request links. If a Click
   webhook is already enabled, its events are kept only in EmailEvent and do
   not create another signer timeline entry. Enable open tracking on the
   stream/messages if you want open events. Save and verify the webhook.
   A verification payload without one of our message UUIDs is acknowledged
   and ignored; it does not create a customer event.
4. Send a test signature request and open its event log from a paid or
   internal account. Delivery is recorded behind the scenes; the existing
   sent entry remains the visible proof of sending. Permanent signer bounces,
   complaints and opens appear in the signer timeline; clicks come from the
   app's own tracking links. Temporary bounces do not show a signer failure.

The optional `POSTMARK_WEBHOOK_IPS` overrides the built-in source IP list
shown in the manifest. Keep the default unless Postmark announces a change
or you are testing with a specific trusted range. Do not allow every IP.
See [Postmark's webhook setup and authentication guide](https://postmarkapp.com/developer/webhooks/webhooks-overview).

The app joins callbacks to the original send using the message UUID in
Postmark metadata. Delivery records success, hard or inactive bounces record
permanent failure, other bounces record temporary failure, and opens/clicks
record engagement. Unsubscribe and manual deactivation are recorded as
suppression, even when inactive; they do not contribute to the hard-bounce
pause. A CC/BCC event is retained for abuse protection but cannot appear as
the signer's event. Unmatched recipients are marked as a recipient mismatch
and are never projected into the signer timeline. Subscription changes record
whether Postmark suppressed sending to that address. A callback with no matching send is ignored, and
repeated callbacks do not duplicate rows or alerts. Only selected fields are
stored; bounce details are limited to 500 characters, and raw message content
is never saved from the webhook.

Events are recorded for every plan because abuse protection needs them.
Only paid and internal accounts see tracking rows in the event-log modal,
newly generated audit PDFs, API event arrays and account-export event counts;
free accounts see an upgrade line in the modal. Existing signed PDFs keep
their original bytes. The webhook commits the event, timeline and pause state
together: a failed pause write returns 500 and leaves the event available to
retry. Operator and customer notifications are attempted independently, in
that order; a notification failure is reported without undoing the pause.
A complaint pauses customer sending, as does a high hard-bounce rate. Internal accounts are exempt. See
[Sending pause](quotas-and-limits.md#3-the-sending-pause-abuse-policy)
for how to investigate and resume sending.

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
`config/schedule.yml`, loaded into Redis when Sidekiq starts. That file is the
only place a recurring job is ever declared (the schedule is loaded with
`source: schedule`, so a job deleted from it is purged from Redis on the next
deploy).

### 4.1 The recurring jobs, and what to do when one has not run

| Job (schedule.yml) | When | What it does | If it stops |
| --- | --- | --- | --- |
| `scheduler_heartbeat` | every minute | Writes the timestamp `/up` reports. | Nothing time-based is running at all — see the heartbeat notes above. |
| `stripe_reconciliation` | `0 6 * * *` (06:00 UTC) | Re-reads every Stripe subscription, repairs drift, cancels duplicate subscriptions, settles refunds an earlier attempt owed, re-enqueues stuck webhook events. Emails the operator **once** if it had anything to fix. | The app's idea of who is paying drifts from Stripe's until it runs again. Safe to run by hand: `StripeReconciliationJob.new.perform` in the console. It is idempotent. |
| `billing_lifecycle` | `15 * * * *` (hourly) | The dunning clock: past-due reminder emails on days 0, 3, 7 and 13, the suspension on day 14, and the seats of invitations nobody accepted (plus any seat hand-back Stripe refused earlier). | Nobody is suspended and nobody is warned; accounts keep paid features they are not paying for, and lapsed invitations keep holding seats the customer is billed for. Hourly, not daily, because day 14 is a deadline that decides whether an account can write. |
| `account_retention` | `30 4 * * *` (04:30 UTC) | The 90-day deletion clock and the dormant-account clock: warning emails (60/30/7 days before a dormancy deletion, one week before a scheduled one) and the purges whose date has passed — plus the account-export housekeeping: a ready export's zip is deleted the night its seven days are up, a failed export's half-built file is cleared up a day later, and a build whose worker died is released so the account's export door opens again. Every sweep runs even if another raises; the job then ends in an error, so the stamp says which night was incomplete. See **docs/account-deletion.md**. | Nothing is destroyed early — every deadline simply slips until it runs. Deletions and dormancy warnings are late, never wrong. But export zips — a copy of a whole account — stay in the bucket past their advertised seven days, and an export whose worker died keeps that account's export button stuck on "being built" until it runs. |

All four are safe to re-run: each decides from the clock and its own dedupe
counters, so a catch-up run after an outage sends what was missed once, not
once per missed tick. If the billing sweep first catches up after day 14, it
sends the missed day-13 reminder alongside the suspension notice, once each.
It also cancels invitations whose holder can no longer sign in because the
login or account was closed, then hands the seat back through the normal
Stripe release process. A failed hand-back stays pending for the next sweep.

The console's **Scheduler** tab (`/operator/scheduler`) is the same evidence
on a page: every job in `config/schedule.yml` with its cron line, its queue,
when it last started and finished, how long it took, whether it worked, the
error it left if it did not, and when it next fires. Every business job has a
**Run now** button — it queues the job in the background exactly as its
scheduled run would (a reason is required and the run is written to the audit
log). The heartbeat has no button: running it by hand would prove nothing.

To check actual firing evidence in a shell instead, run `SchedulerStamps.all`
in the Rails console. It returns the latest attempt for each business job:
start time, finish time, duration in milliseconds, outcome (`ok` or `error`),
and a short error when one escaped the job. `nil` means no stamp is present. An attempt with a
start but no finish is still running, or its worker stopped before finishing.
An `ok` stamp means the job returned normally; check Sentry and operator
alerts for individual account failures that a sweep handled and continued past.

Business-job stamps are JSON in Redis under
`esigncenter:scheduler:last_run:<job_name>`. The heartbeat keeps its existing
`esigncenter:scheduler:last_tick_at` key and is presented in the same shape.
A fresh heartbeat alone does not prove the business jobs ran. If a stamp is
old, inspect the job queue and its errors, then run the relevant job manually
and check the stamp again. Redis loss can erase this evidence. `/up` remains
unchanged and anonymous; these business-job details are read from the console.
No additional scheduler environment variables are needed.

### 4.2 Operator commands for account deletion

Both take an account id, both print what they did, and the first cannot be
undone. The full inventory of what a purge destroys and what survives it is in
**docs/account-deletion.md**.

```
# Destroy one account now, skipping the rest of its 90-day window.
# Prints the orphan counts afterwards — all four must be zero.
bundle exec rake accounts:purge[123]

# Call off a scheduled deletion on the customer's behalf.
bundle exec rake accounts:cancel_deletion[123]
```

`purge` refuses (and alerts) for an account that is not a customer account, or
one that still holds a live paid subscription — an account still being charged
means the cancellation never landed, and that is money leaving somebody's card.
Cancel it at Stripe first. Running it twice is a no-op.

It also refuses an account that is **not due** to be purged — nobody asked for
it, or the 90-day window has not run out, or it is not a dormant account that
has had its final warning — and it refuses an account a purge has already
claimed. To destroy one that is not due anyway, the task makes you say so
twice: `FORCE=1` gets it to print everything the account still holds, and then
`CONFIRM="<the account's exact name>"` has to match before anything is
touched. Both are on one command line, and the task tells you the exact line
to run.

`cancel_deletion` does **not** bring the subscription back: the cancellation
went to Stripe when the deletion was requested and is not reversible from here.
The account lands on the free plan and can subscribe again from its billing
page.

---

## 5. Redis: embedded vs managed

**Decision deferred to launch-gate 3.** This section is the analysis that
decision is made from.

### What lives in Redis today

| Thing | What it is | Lifetime |
| --- | --- | --- |
| Job queues (`default`, `webhooks`, `images`, `documents`, `mailers`, `recurrent`) | Work waiting to run: send this email, deliver this webhook, generate this PDF | Seconds to minutes normally |
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
**two** LibreOffice processes at once by default — the slot keys in Redis
(`WordConverter.max_concurrent`, set by `WORD_CONVERSION_SLOTS`), each
taken atomically, are the real cap, and the cap fails closed when Redis
cannot answer — a 120-second hard timeout that kills the whole process
group, a 20 MB file cap, and 30 conversions per account per hour. Budget a
few hundred megabytes per running conversion on top of the web server's
working set when choosing the tier; the deploy checklist's "Word conversion
memory check" measures it. If the headroom is short: `WORD_CONVERSION_SLOTS=1`
first, then `WORD_CONVERSION_ENABLED=false` (which also stops queued and
slot-waiting conversions — they are marked failed without LibreOffice
starting), then a larger instance. None of those needs a deploy. Details in
`docs/word-uploads.md`.

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
- **A scheduler exists** (`sidekiq-cron`, `config/schedule.yml`). It carried
  one heartbeat job in Session 2; the billing, dunning and retention jobs were
  added to the same file in Sessions 6 and 7 (section 4.1).
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
- **Rotation** (only if the key is believed exposed) is one rake task:

  ```sh
  bundle exec rake operator:platform_cert:rotate
  ```

  It moves the current chain (certificate and its two authority
  certificates — never the private keys) onto an append-only **retired
  list** (`platform_esign_certs_retired` on the operator account), generates
  a fresh identity into the current row, and prints both fingerprints: the
  retired one and the new one. Then **export the new one immediately**
  (section 8.2).

  **Never delete the platform row to rotate.** The public `/verify` page and
  the API verify tool trust the current chain *and every retired chain*, so
  documents signed before a rotation keep verifying forever; a deleted row
  would turn every one of them into "not verified". New signatures carry the
  new identity, so the two fingerprints differ from that moment on. Never
  rotate casually.
- **Nothing generates the certificate except signing, the seed and a
  rotation.** The first customer signing (or `rake operator:seed`, whichever
  comes first) creates the row; the `/verify` page, the API verify tool, the
  E-Signature settings page and the export/fingerprint tasks only *read* it.
  The rotate task is the one deliberate exception: it *generates and writes*
  a replacement identity into the row (after retiring the current chain) —
  and it refuses to run when there is no row yet. With no row, `/verify`
  simply answers "not verified" and the tasks say to run the seed. No
  anonymous upload can mint the platform key.

### 8.4 The timestamp authority is loud now

`TIMESERVER_URL` is required in production; the app refuses to boot without
it. It may hold several URLs separated by commas; each one is a fallback for
the ones before it and **every** one is tried in turn. When none of them
answers, the signing job **fails**: the app reports the failure once (from
the signing job's own error handler — the timestamp code itself does not
report separately), Sidekiq retries the job (a short outage heals itself),
and no document is written with a fake timestamp. Sidekiq's own Sentry
integration is a second, independent channel: it files the retried job's
exception on its own, so Sentry may show the failure under two events. The
old behaviour embedded a locally generated time that looked like a trusted
timestamp but proved nothing.

Customer accounts always use the platform `TIMESERVER_URL`; a timestamp-server
row on a customer account is ignored. Internal accounts may still pin their
own.

### 8.5 Certificates and timestamps are operator-only surfaces

In **Settings → E-Signature**, every admin still sees the signing
preferences (multiple signatures, flatten, download filename) and the card
linking to the public `/verify` page. The rest is visible **only** to the
platform operator; for everyone else those routes return 404, exactly as if
they did not exist. What the operator sees there:

- **Platform signing certificate** — read-only: the product name, the
  SHA-256 fingerprint (compare it with the offline copy) and the valid-until
  date of the certificate every customer account signs with. It cannot be
  changed on this page; the rake tasks in 8.2 and 8.3 manage it.
- **This account's certificates** — the operator *account's own* rows. A
  certificate uploaded here makes the **operator account** sign with it
  instead of the platform certificate; it changes nothing for any customer.
- **Timestamp server** — likewise the operator account's own pin. Customer
  accounts always use `TIMESERVER_URL`; a row saved here does not reach them.

## 9. Support impersonation — looking at a customer's account as one of their people

Sometimes the only way to help is to see what the customer sees. The operator
console can open a **support session**: you look at their account, signed in as
one of their people, and you can change almost nothing while you are there.

### 9.1 How to start one

1. Open **Operator → Accounts** and pick the account.
2. Scroll to **Users** and press **View as this user** on the row you need.
3. The dialog asks for three things:
   - **A reason.** At least ten characters, and write it as a sentence — the
     customer reads this word for word, on their own settings page and in the
     email we send them.
   - **The access level.** *Read-only* (the default: look at everything, change
     nothing) or *Allow document edits* — for fixing a template or a stuck
     document at the customer's request. Even in edit mode, billing, users,
     credentials and signing stay locked, nothing can be deleted permanently,
     and every change you make is logged and shown to the customer.
   - **Your 6-digit authenticator code.** This proves it is really you, right
     now, rather than a laptop somebody left open. Each code works once; if you
     have just used one to sign in, wait for the next one.
4. You land on the customer's dashboard. A yellow bar across the top of every
   page says whose account you are in, as whom, in which mode, for how long, and
   why — with an **End session** button on it.

### 9.2 What is locked, always

Even in "Allow document edits" mode, a support session can never:

- **Touch money** — no Checkout, no Customer Portal, no plan change.
- **Delete the account**, ask for its deletion, or call one off.
- **Touch credentials** — no password change, no email change, no two-factor
  enrolment or removal, no API-token rotation. The pages that would *print* a
  credential are closed outright: the API-token reveal, the MCP tokens page, the
  webhook signing secret and the SMTP settings. The API page itself still opens,
  with the token masked, so you can see that an integration exists.
- **Touch people** — no adding, removing, promoting or parking anybody, and no
  invitations or seat changes.
- **Change settings** — account preferences, notifications, personalization,
  webhooks, e-signature settings and the test-mode toggle are all shut.
- **Sign anything.** Completing a form, declining, delegating, in-person signing
  and self-signing are refused, as the person and as anybody else. That includes
  the round-about routes: creating a submission through the API with a signer
  already marked `completed`, and the "resubmit" door, which opens a fresh
  signing session as the person. The `completed` check asks exactly the
  question the document builder asks — *is there a value there at all* — so
  `completed: "false"`, `completed: 0` or any other spelling is refused just
  the same. A field of the customer's own that happens to be called
  "completed" (a compliance template's "Training completed?") is not a
  completion and does not get in the way. **No signer is ever marked finished
  by a support session.**
- **Delete anything permanently.** Archiving a template or a submission is a
  soft delete the customer can undo, and support may do it. "Delete
  permanently" is a different button: it takes the document, its signers and
  their whole event trail with it, for good. That one is refused — through the
  page and through the API alike — and support asks the customer to press it
  themselves.

Three of these are shut for **every** kind of request, a plain page view
included, because opening them is not a read: the signer's form saves values and
attaches a signature the moment it is opened, the credential pages print the
credential, and an export takes the whole account's data out. To look at a form
the way a signer sees it, use the preview from the template page instead.

The same rules apply to the app's JSON API (`/api/...`) when it is driven from
the browser, so nothing can be done through a fetch call that cannot be done
through a page. Genuine API clients — the ones using an `X-Auth-Token` — are
untouched by any of this.

A refused action is never silent: the page says *"This action is locked"*, a 403
goes back, nothing changes, and a line lands in the audit log. That includes a
refused *start*: a wrong authenticator code, an archived person or a second
session while one is running all leave a row (never the code itself).

In read-only mode the rule is simpler still — **nothing** that writes works,
document edits included.

### 9.2a What "Allow document edits" may do — and what it leaves behind

Edit mode exists for one job: fixing the customer's document when they ask.
Inside it a support session may build and rename templates, upload documents and
detect fields, clone, restore, archive and un-archive, create and archive
submissions, correct a signer's name, email address or phone number, and re-send
an invitation. Everything in 9.2 stays shut, and on top of that the two rules
above — nothing irreversible, and nobody signed for — hold whichever door is
used, page or API.

**Every one of those changes is written down.** Each allowed request in edit
mode leaves an `impersonation.action` line in the audit log naming the exact
action, the record ids it touched, the account, the person it was made as and
the operator who made it. **Exactly one line per request, however the request
ends**, written after the whole request has finished — the error handling
included — so it can say what actually happened:

- `changed` — it went through. This is what the customer's card counts;
- `failed` — the door was open and the request did not go through: any 4xx
  (an upload with no file, a form that failed its own validation, a payload the
  API rejected, a quota or rate limit), or a redirect carrying an alert, which
  is how much of the application says no (a signer on a document that has
  already been opened, for instance);
- `error` — something broke while support was in there. The line still lands,
  so "we touched this and it blew up" is answerable a month later.

A request that was *refused* leaves its refusal line and no action line — never
both. The customer sees the totals too: their Support-access card has an
**Actions** column reading, for example, *"3 actions · 1 blocked"*. **An
"action" there means one allowed edit-mode request that completed**; failed
attempts and errors are in the log with their own outcome and are not counted,
because telling a customer three things were done when three things were turned
away would be worse than saying nothing. A read-only session shows *"Nothing
changed"*, which is the whole promise of that mode, in writing, on the
customer's own page.

### 9.3 The one-hour limit, and ending a session

The authenticator code proves you are you at the moment you start. It cannot be
re-asked on every page, so a session simply ends after **60 minutes**: the next
page you open puts you back on the account's console page with a note saying it
timed out.

Three other things end a session on the very next request, whatever the clock
says: **your platform access being removed** (pull the flag or their two-factor
enrolment and the session is over immediately — this is the "cut this operator
off now" button), **the person being archived**, and **the person moving to
another account**. A support session is a binding between one operator, one
person and one account, and it never follows any of them anywhere. You can also end it whenever you like with **End session** on the
banner, and signing out ends it too. Either way, the exact same audit line is
written.

Test mode and support sessions never overlap. Starting a support session drops
test mode first, and test mode cannot be turned on inside a support session.

### 9.4 What the customer sees

- **An email, straight away**, to every administrator of the account: who was
  viewed as, when, the access level, and the reason you typed — with a line
  telling them to reply if they did not ask us for help. Our own internal
  accounts are the only exception: nobody is emailed, and the history is still
  recorded.
- **A "Support access" card** on their **Settings → Account** page, listing the
  last ten sessions with the date, who was viewed as, the access level, how long
  it lasted, how many actions it actually completed and how many were blocked,
  and the reason. An action is an allowed edit-mode request that completed;
  attempts that failed or errored are in the audit log with their outcome but
  are not counted. Sessions from before we started counting show a dash in that
  column rather than an unearned zero.

### 9.5 Reading the audit log

**Operator → Audit log** (or the History card on the account page) shows three
kinds of row, filterable by action:

- `impersonation.start` — who opened it, on which account, as whom, why, from
  which IP, and the access level in the details.
- `impersonation.refused` — one row per locked door somebody walked into, with
  the path and the controller action. A handful is normal (a click on a settings
  page); a long run of them is worth asking about.
- `impersonation.action` — one row per allowed write an edit-mode session made,
  with the controller action, the path, the record ids and an `outcome`:
  `changed` (it worked), `failed` (the request was allowed but did not go
  through, so nothing changed — a 4xx from anywhere, or a redirect with an
  alert) or `error` (it raised). Read-only sessions never produce one, and a
  refused request never produces one either — it has an `impersonation.refused`
  row instead. If a customer asks "what did you change?", the `changed` rows
  are the answer, in full; the `failed` and `error` rows are the answer to
  "what did you try?".
- `impersonation.end` — how it ended (`operator`, `sign_out`, `timeout`,
  `operator_access_lost` or `rebinding`), how many seconds it lasted, how many
  refusals it collected, and how many actions it completed (the `changed` rows
  only).

Start, refusal and end rows are written inside the transaction that made the
change. The action row is the one exception, and deliberately so: it is written
after the request has finished — outside whatever transaction the action
opened, and after the error handling — because that is the only moment it can
honestly say what happened. **There is no ending that leaves an allowed request
without a row**: a normal response, a 4xx an error handler answered, and an
exception on its way to the 500 page all leave exactly one, with the outcome
that fits. The refusal rows are never affected.
