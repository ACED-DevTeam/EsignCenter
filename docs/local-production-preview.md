# Local production preview on the Mac

Start Docker Desktop, then run from this checkout:

```sh
docker compose -f docker-compose.local-production.yml up -d --build
```

Open **http://localhost:3010**. Rails runs in production mode with eager loading,
caching and precompiled JavaScript/CSS. Navigating does not trigger compilation.
Ruby/template edits require the same build/start command again; ordinary restarts
do not. JavaScript/CSS changes require rebuilding `public/packs` first.

This Mac uses `Dockerfile.local-production`, the existing `esigncenter-app:latest`
dependency image and the compiled `public/packs` directory from the September 16
production build. This avoids duplicating the native toolchain in Docker's small
virtual disk. The regular `Dockerfile` remains the public deployment build. If
the dependency image is absent, build it with `docker build -f Dockerfile.dev -t
esigncenter-app:latest .` on a machine with sufficient Docker disk space.

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
docker compose -f docker-compose.local-production.yml ps
curl http://localhost:3010/up

# Stop, keeping data
docker compose -f docker-compose.local-production.yml stop

# Start the existing compiled version
docker compose -f docker-compose.local-production.yml up -d

# Application logs
docker compose -f docker-compose.local-production.yml logs --tail=100 app
```

The stack restarts when Docker Desktop starts unless explicitly stopped. It is
bound to this Mac's loopback interface. This configuration is for local review;
use the [deployment checklist](render-deploy-checklist.md) for public hosting.
