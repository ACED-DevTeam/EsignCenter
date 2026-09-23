# Local compiled preview on the Mac

The September 23 candidate is running at **http://localhost:3010**, with the
local email inbox at **http://localhost:3011**. It includes upstream commit
`414a9d5e` and preserves the existing test accounts and documents.

The latest production checks require HTTPS and authenticated TLS email. For a
local HTTP walkthrough, the current stack uses a `local_preview` environment
that inherits production eager loading, caching and disabled code reloading,
with asset compilation disabled. This is a local behavior preview, not a
production-configuration preflight. No certificate trust is needed.

The app uses a frozen source snapshot in `tmp/local-production/release` and the
existing compiled packs. JavaScript, stylesheet sources, dependencies and build
configuration did not change in this update; the sole view change changes a
permission condition, without adding CSS classes. A fresh asset rebuild was
attempted but the cached dependency image lacks `@scalar/api-reference`; the
previous compiled packs were preserved and verified over HTTP. Docker's virtual
disk is full, so the snapshot and packs are mounted from this Mac. The snapshot
only adds local environment configuration; deployed production guards remain
unchanged. `release-revision.txt` records the source revision. Do not remove the
snapshot while the preview uses it. Updating the checkout alone does not update
the running snapshot.

Start Docker Desktop, then restart the current compiled snapshot from this checkout:

```sh
docker compose -f tmp/local-production/compose.preview.json up -d --no-build
```

The original `docker-compose.local-production.yml` and
`Dockerfile.local-production` describe the older production-mode setup. They
need HTTPS and SMTP configuration changes before they can boot the new branch;
use the generated preview configuration above for this walkthrough.

This stack has its own PostgreSQL database, uploads, signing certificate and mail
inbox. These are stored in `tmp/local-production/data` on this Mac and survive
container rebuilds. Although Git ignores this directory, it is persistent data:
do not remove it during temporary-file cleanup. The stack does
not use `.env.standalone.local`, deployed accounts, or another app's database.
The app creates its stable local encryption secret in `data/app/docuseal.env`.
Do not delete that secret or the data directory.

Email is captured at **http://localhost:3011**. Sign-up confirmations, password
resets and signing invitations appear there even when addressed to a real email
address; Mailpit does not forward them. Use this inbox to test the full email
flow. Registration uses Cloudflare's official test CAPTCHA keys. Google/Apple
sign-in is unconfigured. Trusted PDF timestamps use DigiCert's public endpoint.

Billing checkout is disabled: the application's production guard requires live
Stripe keys, and this local preview intentionally has none. Paid product features
can be previewed with the existing operator comp-plan control without charging
anyone. This does not verify Stripe checkout or the billing portal.

On an empty database, an operator account and platform certificate must be seeded
before customer signing. Use the existing `operator:seed` task with a local email
and a password supplied privately through the environment (see
[operations](operations.md)). Never reuse production credentials here.

The initialized preview customer is `evan@esigncenter.test`, with a three-seat
paid-feature comp and four starter templates. Its password-reset email is in the
local inbox at port 3011; use that link to choose a password. No Stripe customer
or subscription is created by the comp. New self-serve signups start on Free.

Useful commands:

```sh
# Status and health
docker compose -f tmp/local-production/compose.preview.json ps
curl http://localhost:3010/up

# Stop, keeping data
docker compose -f tmp/local-production/compose.preview.json stop

# Start the existing compiled version
docker compose -f tmp/local-production/compose.preview.json up -d

# Application logs
docker compose -f tmp/local-production/compose.preview.json logs --tail=100 app
```

The stack restarts when Docker Desktop starts unless explicitly stopped. It is
bound to this Mac's loopback interface. This configuration is for local review;
use the [deployment checklist](render-deploy-checklist.md) for public hosting.
