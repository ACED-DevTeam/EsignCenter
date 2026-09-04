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
   once as a matter of course; the second copy never makes a second row. It
   is not simply thrown away, though: if the stored copy has not been decided
   yet, the repeat puts it back on the queue. That covers the case where the
   row was saved but its job was not (the queue was unreachable, or the
   worker died) — without it the event would sit until the next 06:00 sweep.
   Only a copy that is genuinely *waiting* is put back: an event already
   processed or ignored queues nothing, one a worker is holding right now
   queues nothing (deciding that worker died belongs to the stuck-row sweep,
   and a second job would spend one of the event's five retries for nothing),
   and one that has already spent all five is left where the operator can see
   it rather than quietly restarted by a dashboard "Resend".
3. **Enqueue.** A background job is queued. Nothing is processed on the web
   request.
4. **Acknowledge.** `200 {"received": true}`, immediately.

Then the background job does the important part: **it ignores what the event
says and asks Stripe what is true now.** Webhook deliveries arrive out of
order — a cancellation can land before the update that preceded it — and
re-reading the subscription makes order stop mattering. The event is only a
trigger; the object is the truth. That also makes every run repeatable: the
same event processed twice writes the same row.

That re-read, the decision about which subscription the account actually
holds, the write and the dunning clock all happen **inside one lock on the
account's row, taken before Stripe is asked anything** — `StripeBilling::
Linker`, the single path the webhook job, the nightly sweep and the Checkout
return all use. Locking after the fetch instead would let two workers each
hold a snapshot and race for the write, and the older snapshot could land
last — handing paid access back to an account that had just cancelled.

**The trade-off, stated plainly.** Same-account billing work is serialised on
the subscription row — a job or a web request holds its database connection
for its whole duration anyway, so the lock changes nothing about connection
pressure; it only makes two workers on one account take turns. What the lock
must never do is wait forever, so every Stripe call is on a short leash (5 s
to connect, 15 s to read, one retry) and the lock itself gives up after 10 s.
A Stripe outage therefore makes those jobs **fail fast and retry**; it does
not pile them up. A web action that hits the 10 s wait answers with *"try
again in a minute"* rather than an error page.

Inside that lock the rule is short:

- the row holds this same subscription → apply it;
- the row holds nothing → fetch the newcomer; if it is **ours** (below) adopt
  it, otherwise leave it alone;
- the row holds a **different** subscription → ask Stripe about the row's
  **own** subscription — never the cached columns, which can be stale in
  either direction. Still live → the newcomer is a duplicate: it is cancelled
  at Stripe, **whatever it already charged is refunded**, and the operator is
  told; the account keeps the subscription it had. (An invoice never cancels
  anything — it is simply ignored, because the subscription events own that
  decision.) Over → the newcomer is adopted if it is ours.

**What counts as ours.** A Stripe customer can carry subscriptions this app
never sold — another product on a shared Stripe account, something made by
hand in the dashboard. A subscription is ours only if it carries an item on
**our price** (`STRIPE_PRICE_ID`) or our own Checkout tagged it with the
account's id. Anything else is never adopted (no paid access for a purchase
that was not ours) and never cancelled (it is somebody's real purchase); it is
logged as *"foreign subscription … left alone"* and named in the nightly
summary. When a customer somehow holds several live subscriptions of ours, the
survivor is decided the same way every time, in three steps:

1. **Health first.** The one that is actually **collecting** (`active`,
   `trialing`) beats one Stripe is still dunning (`past_due`, `unpaid`,
   `paused`), which in turn beats one that has never charged at all
   (`incomplete` — an abandoned card confirmation).
2. **Then our price.** Between two equally healthy ones, the one carrying an
   item on the price we sell beats one that is merely tagged with the account
   id.
3. **Then the earliest created** — it has been charging longest and is the one
   the customer is most likely to know about.

The rest are duplicates. Health comes first on purpose, and it used to come
second: an `incomplete` subscription sitting on our price beat a `trialing`
one our own Checkout had tagged but whose price had been swapped in the
dashboard — so the app cancelled and refunded the subscription that was
collecting and left the account holding the one that can never pay. Whether a
subscription can collect is the fact that decides who the customer is; which
price it sits on only decides between two that are equally healthy.

**Refunding a duplicate — which one was cancelled decides whether money goes
back at all.** Cancelling a duplicate is only half the job: an account whose
trial is spent pays its first invoice during Checkout, before we ever hear
about it. But *"is this a double charge?"* has two very different answers,
and which one applies is settled by one comparison — was the cancelled
subscription created **after** the one that survived, or **before** it? If
that comparison cannot be made at all — no surviving subscription to compare
against, or a creation date missing from either — the app treats it as the
**older**-loser case: an unproven comparison never moves money on its own, so
the duplicate is still cancelled and a person is asked to look.

**The newer one lost (the ordinary case): everything it collected comes
back.** A subscription created after the survivor never bought anything the
survivor was not already billing for, so every paid invoice of its life is a
second charge. The app asks Stripe what it ever collected — **every** paid
invoice, not just its last one, because a duplicate nobody noticed for three
months charged three times — and sends the money back with the reason
*duplicate*.

**The older one lost: nothing comes back automatically, and a person is
told.** Sometimes the loser is the customer's *original* subscription: their
card started failing, it went `past_due` or never confirmed at all, a healthy
new one appeared and won on health (above). Cancelling the old one is right;
refunding the year it billed honestly is not. At most part of one cycle was
charged twice, and no field on a Stripe invoice says how much of it — so the
app refuses to guess. The old subscription is cancelled under its own marker
(`esigncenter:duplicate-manual`), **no refund is ever issued for it**, the
customer keeps paid access on the survivor, and the operator gets a **manual
refund review** note naming the subscription we cancelled, the one that took
over and when it started, and the last invoice the cancelled one collected —
everything needed to settle the part-cycle by hand in the Stripe dashboard.
The nightly sweep lists these under their own heading in its summary.

Two more rules keep the automatic refund honest.

**One refund per payment, never per invoice.** A refund is made against a
*PaymentIntent* — one card charge — and Stripe lets one charge settle several
invoices. So the duplicate's paid invoices are collapsed onto the payments
that settled them: two invoices behind one $60 charge are **one** debt and get
**one** refund of $60. (Refunding them separately would either return $120 or,
because the two would carry different idempotency keys, fail forever on the
second.) Each refund is capped twice over: by what those invoices collected
through that payment, and by what the charge still has left.

**And the reverse: one invoice settled by SEVERAL payments.** Stripe allows
that too (a card that covered part of an invoice, then another), and each of
those payments states what *it* paid. Each one is a debt of **its own amount**
— never of the whole invoice. Handing the invoice's total to each of them
recorded a $30 invoice as $30 owed twice over, and because each refund is
capped only by what its own card charge still holds (usually plenty), $60 went
back against $30 collected. If several payments settled one invoice and any of
them does not state what it took, nothing is sent at all: there is no honest
way to split a total between payments that do not say what they paid, and a
guess here moves real money. A person is told instead.

**Only what has not already come back.** For each payment the app reads the
charge behind it and refunds **only the part still outstanding**. What counts
as "already back" is capped by what that payment was owed in the first place:
a shared card charge that has had $40 refunded for somebody else's business
has still only settled *this* duplicate's $30, and the debt is square — not
$10 overpaid. A charge an
operator already refunded by hand, or one an earlier attempt of ours returned
before it fell over, counts as returned and is not touched again. That is
what lets a refund that failed half-way simply be retried: the payments
already square are skipped and the rest are finished.

**Never more than three payments unattended.** If a duplicate still owes more
than **three** payments, the app refuses to refund automatically. The
duplicate is cancelled anyway, but the operator gets *"REFUND FAILED — refund
manually"* naming how many payments and how much (*"needs manual review: 4
payments, $120.00 still to return"*), and the event is retried — **for five
attempts, then it pages**. Once a person has refunded by hand there is nothing
outstanding left on any payment, so the next attempt converges quietly and its
note says the charges *"had already been returned"* — never *"nothing was
charged twice"* about a duplicate that took money. A refund that large is not
a duplicate the app understands, and money does not leave automatically faster
than a person can notice.

The total returned (what was already back, plus what went back now) is then
checked against the total those invoices say was collected. If it is short by
a cent, the job **fails loudly** rather than recording a partial return as a
full one: same *"REFUND FAILED — refund manually"*, and the event is retried.
So the figure in the operator alert and in the customer's *"…the duplicate was
cancelled and its charge of $X refunded"* is always a true amount — and when
nothing was actually refunded, the customer is never told one was.

**Every page of the invoices, or none.** The paid-invoice list is read page by
page and stops at a thousand, exactly like the subscription list below; if
Stripe still says there is more, the read is refused rather than treated as
"nothing else was charged" — refunding on half a list would return part of the
money and call it all of it.

Every cancellation the app makes is stamped with one of its two markers —
`duplicate` for a newer loser, `duplicate-manual` for an older one — written
into the subscription's **metadata** at Stripe (`esigncenter_cancelled`,
alongside `esigncenter_cancelled_at`), immediately before the cancellation
itself. Metadata is the marker's authority because only our secret API key can
write it. The same marker is also written in plain words into the
subscription's cancellation comment (`esigncenter:duplicate` /
`esigncenter:duplicate-manual`) purely so it reads sensibly in the Stripe
dashboard — that comment is **never** consulted by the app, because the
Customer Portal's own "tell us more" box writes that same field and a customer
could otherwise type their way to a refund of everything they have honestly
paid. If the metadata write fails, nothing is cancelled: a cancellation
without its marker is a debt the app would forget. A refund is issued only
for a subscription the app cancelled — in this attempt, or in an earlier one
whose refund step failed (the marker proves it). Both markers mean *"we ended
this"*; only the first means *"and we owe its money"*. That earlier attempt is
not forgotten: if the app later finds that the subscription a row still names
is dead **with our automatic marker on it**, it settles that refund before the
row moves on to any other subscription — on the webhook path *and* on the
nightly sweep, which is the only thing left that will ever look once the
subscription is dead (a dead subscription raises no more webhooks). The marker
alone is enough to know the debt: we only ever write it on a subscription
created after the survivor, so its whole paid life is owed, and no surviving
subscription has to still exist for the settlement to be right. A dead
subscription carrying the *manual* marker is left exactly as it is: nothing
sent, nothing said, because a person already has it.

**Being owed money never keeps a customer off the plan they are paying for.**
When the app decides a *person* must send a refund (more payments than it
returns unattended, an invoice naming no payment), the account's row still
moves on to the live subscription the customer is being charged for — the
alternative is somebody paying full price for the free plan while a refund
sits in a queue. The debt is written down twice so it cannot be lost: in the
dead subscription's own Stripe metadata (`esigncenter_manual_refund_owed`),
where an audit finds it, and on the account's row itself
(`refund_owed_subscription_id`), which is what brings the **nightly sweep**
back to it. The sweep retries that settlement every night, and the moment the
reason it could not be paid automatically goes away — an operator refunds part
of it by hand, an unreadable invoice list becomes readable — the rest is sent
and the note is cleared. The same note is made when a duplicate is cancelled
on the ordinary path and its refund is refused there — including at the
Checkout door, which is where double purchases actually come from — because
that refusal rolls the rest of the attempt back and the row would otherwise
end up knowing nothing about a subscription it never named. The nightly sweep
looks at every row carrying such a note, including one that names no
subscription of its own at all.

**One account can only track one such debt at a time** — that is a deliberate
limit of this version, not an oversight. If a second, different duplicate ends
up owing money before the first is settled, the **first one stays** on the row
(it has been owed longest and the sweep is already working on it) and the
operator is emailed about the second by name: *"Second unpaid duplicate refund
for account 123"*, naming the subscription to refund by hand. Both are still
cancelled, and both still carry the marker at Stripe. The sweep names what it
settled in its summary: *"refund settled: $30.00 for sub_…"*.
A candidate that is **already
over** when looked at and carries no marker — a stale webhook about an old,
legitimately ended subscription, a bookmarked return URL — is ignored:
nothing is cancelled, nothing is refunded, nothing is reported as cancelled.

**Two live subscriptions of ours, both real.** If the row holds one and news
of another live one arrives, the survivor policy above decides which the
account keeps (health, then our price, then the earliest created) — not the
order the webhooks happened to arrive in. The loser, whichever it is, goes
through the same cancel-and-refund path. A trial duplicate has paid no
invoice and there is nothing to refund, and the page says *"…you will not be
charged for it."* If the refund itself fails the job fails and retries, and
the alert says **REFUND FAILED — refund manually** so a person looks. Refunds
carry Stripe idempotency keys (one per payment), so a retry inside Stripe's
own 24-hour window lands on the same refund; past that window the charge
itself is what stops a second payout, because only the outstanding part is
ever asked for. Four Stripe calls decide the duplicate path (the row's own
subscription, the duplicate, the cancellation, and what the duplicate ever
collected), then one read of the charge behind each payment that has money in
it, plus one refund per payment there is money to return.

Whether the account is **past due** is decided the same way: from the state
Stripe just reported, not from the kind of event that arrived. A replayed
`invoice.paid` from before a failure cannot stop a clock that is still
running, and the nightly sweep repairs the clock too.

**A completed Checkout has to name a customer this account may act on.** The
browser's return door has always required the session to name *exactly* the
Stripe customer the account's row already holds; the webhook door asks the
same question, or it becomes the way around it — a session paid for by
somebody else's Stripe customer would be linked onto this row and they would
go on paying for it. Two shapes are refused, both recorded as *"customer
mismatch"*, reported once and never retried (a session on another customer
will never become ours):

- the row already holds a **different** customer;
- the row holds none yet, but the customer the session names belongs to
  **another account's** row — the session's `client_reference_id` and its
  `customer` point at two different accounts (a reference copied between
  environments, a session id pasted by hand). This used to get as far as the
  database, where the unique index on the Stripe customer refused it: a failed
  event, five retries and a page for something that can never become ours.

An event that resolves to an internal or operator account — which never bill —
is ignored outright: nothing is applied and nothing is cancelled for it.

A subscription that was **already over** when we looked, and that we did not
cancel, is recorded as *"stale subscription ignored"* — its own words, not the
*"foreign subscription"* used for a stranger's purchase, because it is usually
the customer's own previous, legitimately ended subscription.

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

- a row that disagrees with Stripe is rewritten to match (counted only once
  the repair has actually gone through);
- a customer Stripe says has **two** live subscriptions of ours ends up on
  one of them, and the other goes through the same duplicate path as a
  webhook (cancelled, refunded, reported) — only what was actually cancelled
  is reported as cancelled. Which one survives is the survivor policy's
  decision, not the row's: both are re-read from Stripe under the row lock
  first, so if the subscription the row names is the sicker one, the row is
  moved onto the one that is collecting and the sick one is the duplicate.
  When the one cancelled was the **older** of the two, nothing is refunded
  automatically and the summary lists it under its own **manual refund
  review** heading, with the last invoice it collected, for a person to
  settle by hand;
  What the sweep never does is **adopt**: a live subscription the row has
  never heard of is only named in the summary for a person to look at, never
  written onto the row on the strength of a list. It also skips the duplicate
  check entirely for a row whose repair failed: a stale row is no basis for
  cancelling anything;
- a row still naming a subscription **we** cancelled as a newer duplicate and
  never refunded gets that refund settled here (see above) and named in the
  summary as *"refund settled: $X for sub_…"*. So does a debt the row has
  already moved past and written down (`refund_owed_subscription_id`, above):
  the sweep re-reads that subscription every night until the money is square,
  which is the only thing that will ever look at it again. This is the last backstop for
  it: once the subscription is dead, no webhook about it will ever arrive
  again. One carrying the *manual* marker is left alone — a person owns it;
- **every page** of the customer's subscriptions is read (Stripe pages them;
  ten dead subscriptions cannot hide a live one on the next page). The read
  stops at a thousand; if Stripe still says there is more, the list is
  treated as unreadable — the sweep counts that account as an error and the
  Checkout door refuses to sell (*"try again in a minute"*, with a report)
  rather than conclude "nothing live" from half a list;
- a live subscription that is **not ours** is left alone and named in the
  summary; a live one of ours that no row links to is named too (somebody may
  be paying for nothing — adopting it is a decision for a person);
- inbox rows still unprocessed 15 minutes after they were claimed, and failed
  rows with retries left, are queued again;
- a Stripe error on one account never stops the sweep;
- at the end, if anything at all needed fixing, the operator gets **one**
  email with the counts. Never one per account.

Rows the operator granted by hand (`rake plans:grant`) are marked `manual` and
are never touched by this job. Nor are rows on internal or operator accounts,
which never bill: nothing is repaired or cancelled for them, whatever ids
they carry.

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
- **The secret key's mode must match the environment**: production refuses to
  boot on anything but `sk_live_`, everywhere else refuses anything but
  `sk_test_`. A key that is neither (a truncated paste, a placeholder) is
  refused too — "not obviously a test key" is not good enough to charge
  people with.

#### A note on the test fixtures and the API version

The 13 captured events in `spec/fixtures/stripe/` were recorded at
`2026-07-29.dahlia`, the Stripe account's default at the time, while the app
pins `2026-08-26.dahlia`. Stripe stamps an event with the version it was
created at and re-reading it later does not re-render it, so the only way to
move the captures is to trigger 13 new events — new customers, new
subscriptions, new ids through every example. Instead, the two objects the app
actually reads were fetched at BOTH versions and compared: the subscription
(including `items.data[].current_period_start/end` and the expanded price) is
**byte-identical**, and the invoice differs only in its signed hosted-invoice
URLs, which change on every request anyway. `parent.subscription_details.
subscription` — the shape the invoice handler depends on — is the same in
both. Every retrieve stub in the specs also asserts the exact subscription id
**and** the `expand[]=items.data.price` the app sends, so a missing expansion
cannot pass unnoticed. Recapture when the launch-gate endpoint is created on
the live account.

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
- the **cancel walk** matches the manifest: a cancellation takes effect at the
  **end of the period** (never immediately — the customer keeps the month they
  paid for) and is **not prorated** (no mid-cycle credit; a reduction is never
  refunded), and the customer details they may edit are exactly *email,
  address, name* — `address` in particular, because Checkout collects one and
  it is the only way a customer who moves can fix an invoice;
- an endpoint is registered pointing at `/stripe/webhooks` and listens to
  every event we handle. **No endpoint at all is a warning**, not a failure —
  the dev stack has none and forwards instead. An endpoint that exists but is
  **missing events we handle is a FAIL**: those events would be lost.

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

**An account with a live Stripe subscription is refused by both tasks.** A
local revoke would not stop the card being charged and the next webhook would
undo it; a local grant would take a paying account out of the nightly sweep.
Cancel it at Stripe instead — the Customer Portal or the dashboard — and the
webhook downgrades the account. "Live" means exactly one thing here: the raw
Stripe status last seen. A `manual` row is always the operator's to revoke or
re-grant, whatever stale ids it still carries, and granting over a **dead**
Stripe subscription clears its subscription id and status (the customer id
and the one-trial stamp stay — they are the account's history).

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
| incomplete (paid for, payment not finished) | That the payment has not gone through yet — never a buy button the server would refuse | **Manage billing** |
| ended, trial already used | When it ended (Stripe's own end date, not the end of the period it was paid up to), that documents stay readable and exportable, and that the free trial is spent | **Upgrade to Paid** |
| ended, trial never used | The same, but the trial is still on offer | **Start 14-day free trial** |
| manual (granted by rake) | "Managed by the operator" — nothing to pay, nothing to change | none |

Two doors lead to Stripe, both server-side:

- **Start free trial / Upgrade** posts to `/settings/billing/checkout`. The app
  finds or creates the Stripe customer — one per account, ever: Stripe is
  first searched for a customer tagged with the account (a checkout that
  failed after Stripe answered left one behind), and only then is one created,
  with a body that is the same whoever clicks (the account's name and its
  first admin's email) under a key that is the account itself; a refusal from
  Stripe for that key means the customer exists and it is adopted, never
  duplicated —
  asks Stripe whether that customer already has a live subscription of ours
  it never heard about (every page of them; the survivor is linked, any
  other is cancelled and refunded), and only then creates a Checkout Session
  whose price, quantity (= the people in the account) and trial are decided
  entirely by the server — no request parameter is read for any of them —
  and answers with a 303 to Stripe's page. The whole decision is one step
  under the account's row lock, so two clicks, or a click and a webhook,
  cannot sell the same account two subscriptions. The trial is offered only
  while the account has never had one (`trial_used_at`) — and that question is
  asked **again inside the lock**, on the row it has just re-read, immediately
  before the session is created. The answer the page was rendered with can be
  seconds out of date: the webhook for a first Checkout completed in another
  tab lands in exactly that window, and selling on the stale answer handed the
  account a second 14-day trial. An account that
  already has a live Stripe subscription is turned back with *"You already
  have an active subscription"* and no session is made.
On a subscribed account the page shows **Seats billed** — the quantity Stripe
charges for, frozen at Checkout — and, when it differs, how many people are in
the account today. Dates are shown in the account's own timezone and language.

- **Manage billing** posts to `/settings/billing/portal` and opens the Customer
  Portal configuration from `STRIPE_PORTAL_CONFIGURATION_ID`, where the card,
  the invoices and cancellation live. Seats are not editable there: the app
  owns them.

Coming back from Checkout, `/settings/billing/return` reads the session once
and applies the subscription immediately, so the page tells the truth without
waiting for the webhook. The session has to *be* this account's completed
subscription purchase on **exactly** the customer the account's row already
holds (Checkout made that row and that customer before the session existed,
so "no row yet" or "another customer" is never ours to act on), and a
subscription our Checkout tagged with an account id has to be tagged with
*this* account's. Anything else is turned back with *"We couldn't match this
checkout to your account"* and reported, and no row is created or changed.
The subscription it names then goes through the same locked path
(`StripeBilling::Linker`) as every webhook: if the account already holds a
different live subscription, the new one is the duplicate and is cancelled —
and refunded if it had charged — rather than written over the one that is
charging the card (*"You already had an active subscription; the duplicate was
cancelled…"*, with the refunded amount when there was one). An abandoned
Checkout comes back with *"Checkout cancelled — nothing was charged."*

Reading someone else's billing page is allowed; acting on it is not. A child
account's admin sees the parent's state and gets a 404 from Checkout, the
Customer Portal and the return action, and an operator-granted plan refuses
all three with *"Managed by the operator."*

If Stripe cannot be reached, every one of these answers with one plain sentence
and a Sentry report — never an error page.

Every upgrade call-to-action in the product (`[data-upgrade-cta]`) points at
this page when the person looking at it could buy, and at `/settings/usage`
otherwise, so the link is never dead and never lands anyone on a refusal.

## 10. When the card keeps failing: grace, reminders, suspension

A failed renewal does not take the product away on day one. Stripe reports the
subscription as `past_due` and keeps retrying the card; the app starts a clock
on the first failure (`account_subscriptions.past_due_since`) and gives the
customer **14 days of grace**. Through those 14 days everything works exactly
as before — the paid features included — and the account's admins get four
emails, on **day 0, day 3, day 7 and day 13**. Every one of them says the date
the account will be suspended and links straight to `/settings/billing`.

Day 0 goes out the moment the webhook lands, so the customer hears within
seconds. The other three come from an **hourly** job (`billing_lifecycle` in
`config/schedule.yml`, which also releases the seats of invitations nobody
accepted — §11). Hourly rather than daily because day 14 is a deadline
that decides whether an account can still send: on a daily job an account
would keep sending for up to a day past it, and someone who paid at 09:00
would still be suspended the next morning.

**On day 14 the account is suspended.** So is an account whose subscription
Stripe has given up on entirely (`unpaid`) or paused — there is no grace left
to give at that point, so it happens at once.

### What a suspended account can and cannot do

Suspended means **frozen for writes, and nothing else**:

- Everyone can still **sign in**. Nothing is deleted, ever.
- Every document, template and export stays **readable, downloadable and
  exportable**.
- A signer who already has one of the account's documents open **finishes
  signing it**, and that completion is still recorded. Work in flight is never
  destroyed by a billing problem.
- **Nothing new can be created or changed**: documents, templates, folders,
  people, API keys, webhooks, settings.
- **API keys, MCP tokens, embedded builder tokens and signing-session tokens
  are refused** at the door. A machine door has no page to explain itself on,
  so it simply says the account is not active.
- The **billing page and each person's own profile stay open**, because those
  are the pages that can fix it.

A red banner sits above every page of a suspended account with a link to
`/settings/billing`, and a share link of a suspended account shows the ordinary
"not accepting responses" page to visitors.

A **child account** that is billed through a parent is frozen when the parent
is suspended: the parent is the one who pays.

### Getting out of it

**Paying lifts the suspension automatically**, within seconds of the webhook —
no support ticket, no manual step — and one "your payment went through" email
goes out. So does the subscription simply **ending**: Stripe gives up on an
unpaid subscription about a week after our own day-14 suspension and cancels
it, and at that point there is nothing left to collect — the account goes back
to the free plan and can write again (quietly, with no email: nobody paid). A suspension the operator applied by hand is a different reason
(`accounts.suspension_reason`) and a payment never lifts it; only whoever set
it can.

Internal and operator accounts are the platform itself and are never suspended
by any of this.

## 11. Seats: adding people, and what each one costs

A person is a seat, and a seat is $10 a month. The free plan has exactly one.

### Inviting somebody

An admin invites by email address from **Settings → Users**. On a customer
account this writes an **invitation**, not a user: the invitation holds the
seat, lasts 7 days, and the person themselves chooses their name and password
when they accept it. Nothing half-made is left behind if they never do.

What happens next depends on whether there is a seat free:

- **A seat is free** (the subscription already bills for more people than are
  in the account) — the invitation is written immediately and the email goes
  out. Stripe is not called at all; the seat was already paid for.
- **Every seat is taken** — the admin is shown, before anything happens, what
  Stripe will charge **today** for the rest of the current billing period, and
  what the subscription will cost from the next renewal. Only when they
  confirm is the subscription updated, and only once Stripe has actually made
  the change is the invitation written and sent. A seat is never promised
  before it has been paid for. The figure they are shown is a **preview**
  invoice — nothing is created and nothing is charged by asking for it — and
  the moment it is priced from is pinned and reused for the real charge, so
  the invoice they get is the one they agreed to.
- If the card needs an extra step (3-D Secure), Stripe parks the change rather
  than making it. Nothing is charged, no seat is added and no invitation is
  written; the admin is sent to **Manage billing** to finish it and can then
  invite again.
- An account whose plan the EsignCenter team granted by hand, and a child
  account whose parent pays, cannot buy seats: they get the ordinary "all
  seats are in use" refusal instead.

Pending invitations are listed on Settings → Users with the date they expire,
and can be **resent** (a fresh link, a fresh week) or **cancelled**.

### Seats going back down

A seat comes back when an invitation lapses or is cancelled, when a member is
removed, and when a member is made read-only. The subscription's seat count is
then lowered to the number actually occupied — never below that, and never
below one — with **no mid-cycle refund** (D43): the next invoice is simply
smaller.

**Proration, in one line: additions are, reductions are not.** Adding a seat
is charged immediately for the remainder of the current period (Stripe's
`always_invoice`), because the customer asked for it and saw the number first.
Taking one away is `proration_behavior: none` — no credit, no refund, the next
invoice simply bills fewer seats. Cancelling in the Customer Portal follows
the same rule and is checked for it (§5.3).

The hourly billing job (`BillingLifecycleJob`) is the backstop under all of
it. It notices invitations that have lapsed, retries any hand-back Stripe
refused at the time (an invitation is only marked settled once Stripe has
actually taken the lower number), and brings down any subscription that is
billing for more seats than the account occupies — however it got that way,
including a card step the customer finished later in Stripe's own portal for a
seat whose invitation was never written.

When a paid plan ends with pending invitations still outstanding, those
invitations are **cancelled**: there is no seat left for anyone to take, and
the email about the downgrade says how many were cancelled.

### Being invited when you already have an account

If the invited address already belongs to somebody's own EsignCenter account,
that is not an error. The invitation says so, and accepting **moves** them:
their templates, folders and documents all come into the team, and their old
account is archived (nothing is deleted, and documents it already signed stay
verifiable on `/verify` exactly as they are).

That move is refused, with an explanation rather than an error, when the
account being left has other people in it, still has a paid subscription
("cancel your subscription first"), or is an internal/operator/testing
account. Accepting requires being signed in **as the invited address**.

Who an invitation is for is worked out afresh from the invited address every
time the link is opened, not once when it was sent — because a week is long
enough for the world to move:

- Somebody invited before they had an account, who then signs themselves up
  and only afterwards clicks the link, gets the "join this team" offer rather
  than "that email is already taken". Their seat is the one that was already
  held (and, on a paid account, already bought) for them.
- Somebody who changes their own email address after being invited can no
  longer accept: the page asks them to sign in as the address that was
  invited, and the button refuses. An invitation moves the address the admin
  typed and nothing else.
- If the invited address is already in the team by the time the link is
  opened, the page says so and the seat the invitation was holding goes back.
- An address belonging to a **closed login** (somebody archived in another
  account) cannot be invited at all: nobody can sign in as it, so the
  invitation could never be accepted. The admin is told to invite a different
  address, before any seat is priced or charged.

### Dropping back to the free plan with more people than seats

Nobody is deleted. The admin who signed in most recently keeps full access and
everyone else becomes **read-only**: they can still sign in, read, download and
export everything, and they cannot create or change anything. An email tells
the admins what happened, and Settings → Users has **Give full access** and
**Make read-only** on each person so the admin decides who holds the seats.
Paying again does not undo it automatically — the admin chooses.

An account can never lose its last administrator: removing, demoting,
archiving or making read-only the only person who can administer it is
refused.

## 12. Deleting the account, and money

Deleting an account is its own 90-day flow with its own page —
**[docs/account-deletion.md](account-deletion.md)** — but two things about it
belong here, because they are about the money:

- **The subscription is cancelled the moment the deletion is requested**, so
  nothing is charged again while the 90 days run. Nothing already paid is
  refunded: a customer choosing to leave is not owed the month they used.
- **Calling the deletion off does not bring the subscription back.** A Stripe
  cancellation is not reversible from here, so the account lands on the free
  plan and can subscribe again from the billing page whenever it likes.

The cancellation we make for a deletion is stamped in Stripe metadata with a
**third** marker value (`esigncenter_cancelled = account-deletion`) alongside
the two the duplicate logic uses. That is deliberate: the refund machinery
above only ever acts on `duplicate` (refund automatically) and
`duplicate-manual` (a person decides), so a subscription carrying the deletion
marker reads as *"we ended it, and no money is owed on it"* — which is exactly
right, and means a deletion can never be mistaken for a duplicate and refunded.
