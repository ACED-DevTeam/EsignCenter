# Billing with Stripe (plain English)

EsignCenter sells one thing: **$10 per person per month, with a 14-day free
trial, cancel any time.** This page explains who decides what, what happens
when a payment succeeds or fails, and exactly what has to be configured in
Stripe before real money moves.

Written for the product owner. Every technical word is defined the first time
it appears.

## 1. Who owns what

**Stripe owns the money facts.** Whether a subscription is on trial, live,
late or over; when the current month ends; how many seats are being charged;
what card is on file; what the invoices say. We never argue with Stripe about
any of it.

**The app owns the verdict.** One column on the account — `access_state` —
says whether the paid features are on. It is written only from what Stripe
says. Everything else in the product (the API, webhooks, branding removal,
reminders, custom email) asks the same question through `Plans` /
`Entitlements`, so there is exactly one place where "is this account paid?"
is decided.

**The app also owns seats.** How many people are in the account is the app's
number, not something a customer types into Stripe. That is why the Stripe
Customer Portal has quantity editing switched OFF (section 5).

## 2. The state table

Stripe's own word for a subscription (`status`), plus its "cancel when the
month ends" flag, become the app's verdict like this:

| Stripe says | Cancel at period end | The app's `access_state` | Paid features |
|---|---|---|---|
| `trialing` | no | `trialing` | **on** |
| `trialing` | yes | `canceling` | **on** |
| `active` | no | `active` | **on** |
| `active` | yes | `canceling` | **on** |
| `past_due` | either | `past_due` | **on** |
| `unpaid` | either | `suspended` | off |
| `paused` | either | `suspended` | off |
| `incomplete` | either | `cancelled` | off |
| `incomplete_expired` | either | `cancelled` | off |
| `canceled` | either | `cancelled` | off |
| anything we do not recognise | either | `cancelled` | off |

Two deliberate choices in that table:

- **`past_due` keeps the features on.** A renewal that has not gone through
  yet is a card problem, not a decision to leave. Stripe retries the card for
  days; taking the product away on day one would punish a customer for an
  expired card. When Stripe finally gives up, the subscription becomes
  `unpaid` and the features go off.
- **`canceling` keeps the features on.** A customer who cancelled has paid
  for the month they are in and keeps it until the end of it.

A downgrade **never deletes anything**. When a subscription ends, the row
keeps every Stripe id it had, so the history stays readable and a later
purchase simply attaches a new subscription id. Documents stay readable and
exportable forever.

**One trial per account, ever.** The first time a subscription with a trial is
seen, the account is stamped `trial_used_at` and that stamp is never cleared.

## 3. How a Stripe event reaches the app (the inbox contract)

Stripe tells us things by posting to `POST /stripe/webhooks`. Four steps, in
this order, and nothing else happens on that request:

1. **Verify.** The body is checked against the `Stripe-Signature` header using
   `STRIPE_WEBHOOK_SECRET`, with Stripe's own 5-minute freshness window. A
   body we cannot prove came from Stripe gets a bare `400` and is not stored.
   If the app has no webhook secret at all it answers `503` — it will not
   store an unverified body.
2. **Store once.** The exact bytes Stripe signed go into the
   `stripe_event_inboxes` table, keyed by Stripe's event id. Stripe retries a
   delivery until it is acknowledged, so the same event arrives more than
   once as a matter of course; the second copy is acknowledged and dropped.
3. **Enqueue.** A background job is queued. Nothing is processed on the web
   request.
4. **Acknowledge.** `200 {"received": true}`, immediately.

Then the background job does the important part: **it ignores what the event
says and asks Stripe what is true now.** Webhook deliveries arrive out of
order — a cancellation can land before the update that preceded it — and
re-reading the subscription makes order stop mattering. The event is only a
trigger; the object is the truth. That also makes every run repeatable: the
same event processed twice writes the same row.

Events for a customer no account owns (a shared test key, a deleted account)
are recorded, reported once, and never retried. An event type we have no
handler for is stored and marked ignored — nothing is ever silently dropped.

A job that fails is retried five times. After the fifth, the operator gets an
email naming the event, and the row can be re-run by hand from the console.

**The webhook endpoint is deliberately open even while `BILLING_ENABLED` is
off.** That switch decides whether customers can reach the billing pages, not
whether Stripe may talk to us. A subscription that changes while the switch is
off still has to be recorded, or the app's idea of who is paying goes
permanently wrong.

## 4. The nightly safety net (reconciliation)

Webhooks get lost — an endpoint rotated, a deploy that dropped a delivery, a
bug that marked a row failed. So at **06:00 UTC every day** a job re-reads
every subscription the app thinks it has, straight from Stripe:

- a row that disagrees with Stripe is rewritten to match (and counted);
- inbox rows still unprocessed 15 minutes after they were claimed, and failed
  rows with retries left, are queued again;
- a Stripe error on one account never stops the sweep;
- at the end, if anything at all needed fixing, the operator gets **one**
  email with the counts. Never one per account.

Rows the operator granted by hand (`rake plans:grant`) are marked `manual` and
are never touched by this job.

## 5. What has to be configured in Stripe

### 5.1 The Customer Portal (the manifest)

The portal is the page a customer lands on when they click **Manage billing**.
It is created by `rake stripe:portal_configuration`, never by hand in the
dashboard, so the configuration is reviewable in code. What it allows:

| Feature | Setting | Why |
|---|---|---|
| Invoice history | on | Customers can download their own receipts. |
| Payment method update | on | The fix for a failed payment. |
| Cancel subscription | on, **at period end**, no proration, with a reason picker (too expensive / missing features / switched service / unused / too complex / low quality / other) | They keep the month they paid for, and we learn why they left. |
| Change plan or quantity | **off** | Seats belong to the app — the people in the account. Two writers on one number would fight. |
| Update customer details | on (email, address, name) | Invoice details are theirs to correct. |
| Return URL | the app's own `/settings/billing` | They come back where they started. |

Run it once per Stripe account (test and live are separate):

```
bundle exec rake stripe:portal_configuration
```

It prints a `bpc_…` id. Put that id in `STRIPE_PORTAL_CONFIGURATION_ID`. The
task is safe to re-run: if a configuration for the current manifest version
already exists it prints that one instead of making another.

### 5.2 The configuration manifest (environment)

| Variable | Shape | What it is |
|---|---|---|
| `STRIPE_SECRET_KEY` | `sk_live_…` in production, `sk_test_…` elsewhere | The API key every call is made with. A test key in production **refuses to boot**. |
| `STRIPE_PUBLISHABLE_KEY` | `pk_…` | The public key. |
| `STRIPE_WEBHOOK_SECRET` | `whsec_…` | Verifies incoming webhooks. Blank ⇒ the endpoint answers 503. |
| `STRIPE_PRICE_ID` | `price_…` | The single price sold: $10 / seat / month. |
| `STRIPE_PORTAL_CONFIGURATION_ID` | `bpc_…` | From `rake stripe:portal_configuration`. |
| `BILLING_ENABLED` | `true` to open | The launch switch for the billing **pages**. The webhook stays open regardless. |

Two more facts pinned in code, not in the environment:

- **API version `2026-08-26.dahlia`.** Every request names it explicitly, so a
  Stripe gem upgrade cannot silently change what the responses look like.
  Changing it is a deliberate migration.
- **Nothing is read at boot.** Every Stripe setting is read fresh at the
  moment it is used, so the test suite can hand each test its own fake
  credentials and a rotated key takes effect on the next request.

### 5.3 Checking it

```
bundle exec rake stripe:check
```

Prints a PASS/FAIL table and exits non-zero on any FAIL. It asserts, against
the **live** Stripe account:

- all five variables are set and shaped right;
- the price is active, USD, $10.00, recurring monthly;
- the portal cannot edit seats, and can cancel, update the card and show
  invoices;
- an endpoint is registered pointing at `/stripe/webhooks` and listens to
  every event we handle (a *warning*, not a failure — the dev stack has no
  registered endpoint, it forwards instead).

## 6. Running it on the dev stack

The dev stack has no public URL, so Stripe cannot post to it. The Stripe CLI
forwards instead. In a terminal on your Mac:

```
stripe listen --forward-to localhost:3015/stripe/webhooks
```

It prints a `whsec_…` secret **for this session**; put that in the dev
environment file as `STRIPE_WEBHOOK_SECRET` and restart the app container.
Leave the `stripe listen` window open while testing; every event Stripe
generates in test mode appears there and is forwarded.

## 7. Launch checklist for real money

1. Create the **live** price ($10, monthly, USD) on the live Stripe account
   and put its id in `STRIPE_PRICE_ID`.
2. Run `rake stripe:portal_configuration` against the live account and set
   `STRIPE_PORTAL_CONFIGURATION_ID`.
3. In the Stripe dashboard, add a webhook endpoint at
   `https://<your host>/stripe/webhooks` listening to exactly:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `customer.subscription.paused`
   - `customer.subscription.resumed`
   - `customer.subscription.trial_will_end`
   - `invoice.paid`
   - `invoice.payment_failed`
   - `invoice.payment_action_required`
4. Copy that endpoint's signing secret into `STRIPE_WEBHOOK_SECRET`.
5. Set `STRIPE_SECRET_KEY` / `STRIPE_PUBLISHABLE_KEY` to the **live** keys.
6. Run `bundle exec rake stripe:check` in the production shell. Everything
   must say PASS (the endpoint line may be the only WARN, and only if step 3
   was skipped).
7. Only then set `BILLING_ENABLED=true`.

## 8. Granting and revoking by hand

For a partner, a refund case, or an account being looked after outside Stripe:

```
bundle exec rake "plans:grant[<account id>,<seats>]"
bundle exec rake "plans:revoke[<account id>]"
```

Both resolve the **billing account** first: an account that is another
account's child is paid for by its parent, and the task says so before it
writes (`Billing account is #12 (parent of #34)`). Internal and operator
accounts are refused — they are the platform and never bill. A hand-granted
row is marked `manual` and the nightly Stripe sweep leaves it alone.

---

## 9. What the customer sees (`/settings/billing`)

The page lives next to **Usage** in account settings and appears only for
someone who could actually act on it: the `BILLING_ENABLED` switch on, a
customer account (internal and operator accounts get a 404), and an admin of
that account. It always talks about the **billing account**, so a child account
sees its parent's subscription, is told *"Billing is managed by <parent>"*, and
gets no buttons.

What each state shows:

| State | The page says | Button |
|---|---|---|
| free | The Free plan with its real limits (read live from the quota engine) beside the Paid plan, its price and six headline benefits | **Start 14-day free trial** |
| trialing | When the trial ends, the seats, and what it will cost afterwards, plus the note that cancelling before the end costs nothing | **Manage billing** |
| active | The renewal date, the seats and the monthly amount | **Manage billing** |
| canceling | The date the subscription ends and that it can be resumed in the portal | **Manage billing** |
| past_due | A warning banner: the last payment failed, update the card | **Manage billing** |
| suspended | An error banner: paid features are off until the payment is settled | **Manage billing** |
| ended (cancelled with a past subscription) | When it ended, that documents stay readable and exportable, and that the free trial is spent | **Upgrade to Paid** |
| manual (granted by rake) | "Managed by the operator" — nothing to pay, nothing to change | none |

Two doors lead to Stripe, both server-side:

- **Start free trial / Upgrade** posts to `/settings/billing/checkout`. The app
  finds or creates the Stripe customer, then creates a Checkout Session whose
  price, quantity (= the people in the account) and trial are decided entirely
  by the server — no request parameter is read for any of them — and answers
  with a 303 to Stripe's page. The trial is offered only while the account has
  never had one (`trial_used_at`). An account that already has a live Stripe
  subscription is turned back with *"You already have an active subscription"*
  and no call is made.
- **Manage billing** posts to `/settings/billing/portal` and opens the Customer
  Portal configuration from `STRIPE_PORTAL_CONFIGURATION_ID`, where the card,
  the invoices and cancellation live. Seats are not editable there: the app
  owns them.

Coming back from Checkout, `/settings/billing/return` reads the session once
and applies the subscription immediately, so the page tells the truth without
waiting for the webhook — a session belonging to another account is ignored,
and the webhook says the same thing again, idempotently. An abandoned Checkout
comes back with *"Checkout cancelled — nothing was charged."*

If Stripe cannot be reached, every one of these answers with one plain sentence
and a Sentry report — never an error page.

Every upgrade call-to-action in the product (`[data-upgrade-cta]`) points at
this page when the person looking at it could buy, and at `/settings/usage`
otherwise, so the link is never dead and never lands anyone on a refusal.
