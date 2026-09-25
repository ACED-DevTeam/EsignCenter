# Local compiled preview on the Mac

The September 25 candidate, upstream commit `cc564003` (PR #6), runs at
**http://localhost:3010**. The local email inbox is at **http://localhost:3011**.
Existing test accounts and documents are preserved. **Stripe TEST mode is on**:
checkout, the Customer Portal, Business and API packs use the EsignCenter
sandbox account and never charge real money.

This is a local behaviour preview, not a production-configuration preflight.
It runs the `local_preview` Rails environment, which loads `production.rb`
(eager loading, caching, no code reloading) but uses plain HTTP and a local
mail catcher. In this environment the Stripe guard accepts only `sk_test_` keys.

## What runs where

All files are under `tmp/local-production/` (ignored by Git):

- `compose.preview.json`: containers `esigncenter-local-production-{app,postgres,mailpit}`.
- `release-cc564003/`: the frozen source snapshot (`git archive` of the
  revision plus the four `local_preview` config files) and its compiled
  packs in `public/packs`. `release-revision.txt` records the revision. The
  previous snapshot, `release/` (`6b6cdc87`), is no longer used and can be
  deleted once you are happy with this one.
- `preview.env` (mode 600): Stripe test keys, prices, portal id and webhook
  secret. Never commit or paste it.
- `data/`: PostgreSQL, uploads, signing certificate, mail and the app's
  encryption secret (`data/app/docuseal.env`). This is persistent data. Do not
  delete it during cleanup.
- `backups/`: database dumps taken before updates.

The app runs `rails db:migrate` before Puma on every start. Updating the
checkout does not update the preview. A new revision needs a new snapshot,
a production pack build and an update to `compose.preview.json`.

## Commands

```sh
cd ~/GitHub/EsignCenter/tmp/local-production

# Stack: status, start, stop (keeps data), logs, health
docker compose -f compose.preview.json ps
docker compose -f compose.preview.json up -d
docker compose -f compose.preview.json stop
docker compose -f compose.preview.json logs --tail=100 app
curl http://localhost:3010/up

# Stripe webhook forwarder (runs only while this Mac is on)
./stripe-listen.sh start     # background; log in stripe-listen.log
./stripe-listen.sh status
./stripe-listen.sh stop

# Verify the Stripe configuration (all PASS; the endpoint line is a WARN
# because events are forwarded by the listener rather than a dashboard endpoint)
docker exec esigncenter-local-production-app-1 bundle exec rake stripe:check
```

The stack restarts when Docker Desktop starts unless you stopped it. The
webhook listener does **not** restart with it. After a reboot, run
`./stripe-listen.sh start` before testing billing. Without the listener, the
app does not receive Stripe events. The Checkout return page still links the
subscription, but later changes, such as a portal cancellation, are delayed
until the listener is running. The listener uses the sandbox key from
`preview.env` because the Stripe CLI's own login is a different Stripe account.
Its signing secret is stable. `./stripe-listen.sh secret` rewrites it into
`preview.env` if it ever changes; after that, recreate the app with
`docker compose -f compose.preview.json up -d`.

## Stripe test mode

- Prices: Paid seat $10 (`STRIPE_PRICE_ID`, carried over from the dev
  environment), Business $49 `price_1UJcJR4rEeOqtLcXiI921gQx`, API pack $10
  `price_1UJcJR4rEeOqtLcXfISF5rMe` (created by `rake stripe:api_prices`).
  Portal configuration: `bpc_1UBTA24rEeOqtLcXE6AvA54L` (manifest version 1,
  unchanged).
- Test cards (any future expiry, any CVC and ZIP):
  `4242 4242 4242 4242` succeeds; `4000 0000 0000 0341` is accepted at
  Checkout but fails at the first charge; `4000 0025 0000 3155` requires 3-D
  Secure authentication; `4000 0000 0000 9995` is declined.
- On Stripe's Checkout page, choose **Card**. Clear "Save my information for
  faster checkout" if you do not want it to ask for a phone number.
- Trials last 14 days. To see what happens at the end of a trial without
  waiting, use a Stripe test clock in the sandbox dashboard.

## Accounts

Mail is captured at **http://localhost:3011**, including mail addressed to
real addresses. Mailpit never forwards it. Sign-up confirmations, password
resets and signing invitations all appear there.

- **Pre-made account** `evan@esigncenter.test`: operator comp (three seats,
  paid features, no Stripe subscription) and starter templates. On
  http://localhost:3010/sign_in, choose "Forgot your password?", then open the
  reset email at port 3011 and choose a password. Because this account is on a
  comp, it does not show Stripe checkout.
- **Fresh account** (to test billing): choose "Create Free Account", use any
  address (for example `you+1@esigncenter.test`), confirm it from the inbox at
  port 3011, sign in, then open Settings → Billing → Start 14-day free trial.
  The CAPTCHA uses Cloudflare's always-pass test key. Google/Apple sign-in is
  not configured.

Trusted PDF timestamps use DigiCert's public endpoint. The configuration is
bound to this Mac's loopback interface. Use the
[deployment checklist](render-deploy-checklist.md) for public hosting.
