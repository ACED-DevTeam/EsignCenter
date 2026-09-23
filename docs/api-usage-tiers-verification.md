# D79 implementation and round-1 verification

Status: done. Round-1 implementation commit: `6e5545ae`.

Branch: `feature/api-usage-tiers`. Initial implementation checkpoints were
`9f60554c` and `d7ae8f8a`. This report supersedes their implementation defaults
where the lead amended D79 on September 23, 2026. No push, PR, deployment or
Stripe account/network operation was performed.

## What changed in round 1

- `lib/quotas.rb`, `ApiMeteringActivation`, completion snapshots and quota/request
  specs: new documents reserve API capacity. One SQL snapshot combines this
  month's first-signer completions with eligible open documents under the
  existing billing-account creation lock. Completion replaces its reservation;
  decline, expiry or archive releases it. Still-open reservations survive a UTC
  month reset. Documents already sent always finish.
- Public share controllers, SDK and views return to the base source `link` and
  SAMEORIGIN framing. The new share-embed classification and `?embed=1` parameter
  are removed. Existing API/signing-session/MCP doors retain quota enforcement.
  Counted-lineage corrections bypass the API cap; dashboard Resubmit remains an
  in-app action. No framing capability is added by this feature.
- `lib/stripe_billing/tier_changes.rb`, `subscription_sync.rb`, and the
  subscription model reuse item prices where possible. Pending updates never
  contain deleted items. Paid → Business upgrades charge the prorated difference
  now; Business → Paid changes the next renewal with no credit while locally
  retaining Business access until then. Reversing that pending downgrade does
  not charge for Business again.
- `lib/stripe_billing/pack_purchases.rb`, `ApiPackPurchase` and billing jobs
  purchase only new units at the full monthly price through a durable standalone
  invoice operation. Purge protections preserve the recovery ledger. Capacity is applied after confirmed
  payment, then recurring quantity is changed with proration disabled. Packs
  during trial are available immediately and billed at trial end. Reductions
  apply at renewal; restoring still-paid capacity does not charge twice.
- Any explicit API override disables and refuses plan/pack purchases, including
  zero and unlimited. Billing links agreement customers to Support. Both usage
  meters separately show open reservations and explain that they survive reset.
- `app/views/marketing/pricing.html.erb` and `lib/pricing_matrix.rb` add a sticky
  feature column, mobile swipe hint, matching card lists,
  an available Business signup button, concise pack prices and Enterprise feature
  checkmarks. Terms, help and billing copy describe the amended billing rules.
  Terms `2026-09-24` is archived unchanged; the current version is `2026-09-25`.
- D79's external plan record has the requested dated lead-amendment sub-list.

## Defaults and implementation choices beyond D79

1. Checkout still starts on Paid; Business is selected in Billing after signup.
   Registration-disabled pricing links sign-in instead of an unavailable signup.
2. Pack forms accept a target recurring quantity from 0 to 9999. Both plans and
   packs require an active/trialing, self-billed subscription. Manual grants,
   children, deletion/cancellation/dunning, pending payments and externally
   scheduled subscriptions cannot use the purchase controls.
3. Renewal reductions use changed recurring Stripe items plus retained local
   entitlement, without Stripe schedules. This preserves existing seat changes.
   UTC completion resets and subscription renewal remain independent.
4. Standalone pack invoices use a persisted purchase UUID and stable Stripe
   idempotency keys. Payment webhooks and nightly reconciliation recover paid
   operations. Only matching invoice/customer/amount data grants capacity.
   Unknown-invoice creation stops after 23 hours to stay inside Stripe's
   idempotency window; unpaid purchases expire after 24 hours and are voided
   on retry/reconciliation. Drafts are finalized without automatic collection
   before voiding, so lost responses remain recoverable. Ambiguous unknown
   invoices remain open for operator recovery. Paid purchases that cannot be
   fulfilled after cancellation become operator-review/refund debts. The ledger
   survives purge and prevents cascading subscription deletion. Standalone
   invoice lines are non-discountable; automatic tax remains off under D22/D22a.
5. API overrides are absolute: blank inherits, zero refuses new automation and
   -1 is unlimited. They grant no API entitlement to Free. Zero emits no
   percentage warning. Warning emails count completions, not reservations.
6. Activation defaults to a durable deployment-migration timestamp, rather than
   process start. A schema-loaded fresh database initializes it before first API
   creation. Completion rows snapshot submission creation time, preserving grace
   after deletion. Old deleted rows lacking that time remain excluded.
7. Enterprise uses the existing `/support` path; no Enterprise plan/Stripe price.
   New application strings use the existing English fallback; marketing/legal
   remain English. The Terms date follows the next-date rule in `docs/legal.md`.

## Deployment and Stripe setup

Run `bundle exec rails db:migrate` before starting the updated app. Initial
migration `20260923120000_add_api_usage_tiers.rb` adds subscription plan/pack
quantities, retained packs and API limit override. Round-1 migration
`20260923130000_finalize_api_tier_billing_and_activation.rb` adds retained
Business expiry, durable pack purchase operations, the API activation singleton,
and a backfilled submission-creation timestamp on completion records.

Keep `STRIPE_PRICE_ID` as the existing $10/month seat price. Optional distinct
monthly USD prices:

- `STRIPE_BUSINESS_PRICE_ID`: $49/month base, including one seat.
- `STRIPE_API_PACK_PRICE_ID`: $10/month recurring pack, including 50 completions.

Missing optional IDs leave existing Paid subscriptions working with their
50 allowance and make corresponding purchases unavailable with honest copy.
Retain each ID once sold. `bundle exec rake stripe:api_prices` creates/finds the
prices and `bundle exec rake stripe:check` verifies them; both contact Stripe
and were **not run**. Keep Customer Portal quantity editing disabled.

`API_METERING_STARTS_AT` optionally pins a fixed ISO8601 activation timestamp,
for example `2026-10-01T00:00:00Z`. If absent, the new migration records its own
execution time once. Restarting or redeploying never advances that default.
Only documents created at/after this time contribute to API completions,
reservations or warnings. Before a future activation, creation is unrestricted
by the API allowance. Existing old documents remain signable and excluded.
Set the same fixed value for web/worker processes and do not move it on normal
redeployments. Backdating it deliberately removes some rollout grace.

Follow `docs/legal.md` for the owner's pre-effective-date administrator notice
and counsel review. No messages were sent by this implementation worker.

## Verification environment

Used development image `esigncenter-app:latest` in task-owned
`esign-api-tiers-r1-app`, mounting only this worktree. Task-owned PostgreSQL 18
`esign-api-tiers-r1-db` uses disposable databases `docuseal_test`,
`docuseal_ui_test`, and `docuseal_billing_test`; credentials shown in commands
below belong only to this disposable instance. Four already-locked gems missing
from the image were installed inside the container; the lockfile is unchanged.
The cached JavaScript dependencies were also refreshed with
`docker exec esign-api-tiers-r1-app yarn install --frozen-lockfile`, then assets
rebuilt using `docker exec esign-api-tiers-r1-app bundle exec ruby bin/shakapacker`.
The final build passed with zero errors and two existing Scalar dependency
warnings. The first build exposed missing cached packages; no dependency file
was edited. Explicit recompilation was necessary because ERB-only changes had
left the old CSS digest in place, omitting the new table minimum-width utility.
PostgreSQL uses a 1 GB tmpfs to avoid the shared Docker disk limit. Browser
TMPDIR lives under host-mounted `/app/tmp`.

## Commands and results

Raw logs and new screenshots live under `tmp/api-tiers-round1/` (quota logs
under `tmp/api-tiers-r1/`).

UI/settings/legal/help/usage and related system specs:

```sh
docker exec -e TMPDIR=/app/tmp \
  -e DATABASE_URL=postgresql://postgres:postgres@esign-api-tiers-r1-db/docuseal_ui_test \
  esign-api-tiers-r1-app bundle exec rspec \
  spec/golden/api_usage_settings_spec.rb spec/golden/marketing_spec.rb \
  spec/golden/legal_spec.rb spec/golden/help_spec.rb \
  spec/golden/usage_page_spec.rb spec/system/billing_settings_spec.rb \
  spec/system/api_settings_spec.rb
```

Initial round-1 run: **108 examples, 1 failure** in a trial fixture that set
Stripe status without the mirrored access state. Corrected the fixture and
reran `spec/golden/api_usage_settings_spec.rb` with the same container/env:
**9 examples, 0 failures**. After the reservation meter and renewal-price label
were added, reran the whole command above on released `docuseal_test` (omit
`DATABASE_URL`): **108 examples, 0 failures**, 27.1s. No assertion was weakened.

Broad quota/request verification:

```sh
docker exec esign-api-tiers-r1-app bundle exec rspec \
  spec/golden/api_usage_tiers_spec.rb spec/golden/quota_spec.rb \
  spec/golden/gating_spec.rb spec/golden/operator_console_spec.rb \
  spec/lib/plans_spec.rb spec/lib/entitlements_spec.rb spec/requests
```

**522 examples, 0 failures**, 7m44s. Earlier focused run: 109 examples,
1 failure caused by a cached absent override in a fixture; reload corrected it,
and the 23 API-usage examples passed before the final broad run. D42 behavior
for in-app sources remains unchanged. Public-share files were also compared
byte-for-byte with the base before D79 (`9f60554c^`).

Billing/Stripe/seats/operator revenue and full lifecycle/purge verification:

```sh
docker exec -e TMPDIR=/app/tmp \
  -e DATABASE_URL=postgresql://postgres:postgres@esign-api-tiers-r1-db/docuseal_billing_test \
  esign-api-tiers-r1-app bundle exec rspec \
  spec/golden/api_billing_spec.rb spec/golden/billing_page_spec.rb \
  spec/golden/stripe_spec.rb spec/golden/seats_spec.rb \
  spec/golden/operator_console_spec.rb:1350 \
  spec/golden/lifecycle_downgrade_spec.rb
```

**526 examples, 0 failures**, 1m53.96s. Focused API-billing plus lifecycle/purge
run: **131 examples, 0 failures**. Earlier combined run: 435 examples,
1 failure in the deliberate rollback/retry fixture; corrected its stale
in-memory signed-in user. Exact full Stripe mutation bodies are matched by
WebMock, with an additional regression rejecting any pending/deleted pairing.
Recovery cases cover paid-before-local-failure, cancellation, unknown invoices,
lost expiry responses, trial packs, overrides, and tier/pack round trips.
Late pack webhooks after a real account purge retain normal PII scrubbing.

Final gates:

```sh
~/.local/bin/box-lock run --label esign-api-tiers-r1-gates -- \
  docker exec -e TMPDIR=/app/tmp esign-api-tiers-r1-app bundle exec rake gates:all
```

**PASS**: isolation, account-kind, branding, RuboCop, ERB lint, ESLint and
Brakeman. RuboCop: **784 files, 0 offenses**. ERB: **474 files, 0 errors**.
Brakeman: **0 errors, 0 security warnings**, 7 existing ignored warnings.
`git diff --check` passes. No lint rules, exclusions or tests were weakened.

## Browser evidence

```sh
~/.local/bin/box-lock run --label esign-api-tiers-r1-browser -- \
  docker exec -e TMPDIR=/app/tmp/api-tiers-round1/browser-tmp \
  -e DATABASE_URL=postgresql://postgres:postgres@esign-api-tiers-r1-db/docuseal_ui_test \
  esign-api-tiers-r1-app bundle exec rspec \
  tmp/api-tiers-round1/browser_spec.rb --format progress
```

**7 examples, 0 failures**, 11.2s. Sol collected actual Cuprite evidence at desktop
1440×1000 and phone 390×844. Initial browser runs were 7 examples/1 failure:
pricing overflow at phone width. Rebuilding stale CSS restored the new table
minimum width; a real remaining overflow came from absolutely positioned
screen-reader labels whose containing block was outside the scroll region.
Making that region positioned fixed the overflow without hiding content or
weakening assertions. Blank viewport captures were replaced with crops from
actual full-page screenshots and opened to confirm real rendered pixels.

Final screenshots under `tmp/api-tiers-round1/screenshots/`:

- `pricing-{1440,390}.png`.
- `pricing-comparison-{initial,business,enterprise}-390.png`: phone crops at
  three horizontal scroll positions, each with the visible swipe hint and
  sticky feature column. Matching `*-390-full.png` captures preserve context.
- `billing-business-{configured,unconfigured,trial-packs,agreement,downgrade-pending}-{1440,390}.png`.
- `api-business-390.png`, `billing-invalid-packs-390.png`,
  `billing-free-{1440,390}.png`.
- `business-signup-390.png`, `enterprise-contact-390.png`.

Observed interactions: the Business CTA opens signup; Enterprise opens Support;
API usage links to Billing; invalid pack quantity produces the server error;
trial packs have an editable form and trial-end billing copy; agreement
customers have no plan/pack purchase controls; pending downgrade shows retained
Business capacity, its renewal date, future price and Keep Business action.
Phone table scrolling exposes Business and Enterprise while feature labels
stay visible. All page-overflow assertions pass. Empty usage, unavailable
products and validation errors are included; these pages introduce no separate
loading state.

Astra opened the desktop pricing, phone comparison crops and updated billing
screenshots for inspection. No Opus/Fable reviewer is available in this runtime;
the lead retains visual sign-off. A failed pre-fix phone screenshot is preserved
as `pricing-390-before-relative.png`; it is diagnostic, not final evidence.

## Limits of verification

The full repository RSpec suite is not run. Real Stripe test-mode tier and pack
flows remain a **pre-merge lead check**: supported parameter combinations,
invoice payment/authentication, retries, renewal boundaries and trial billing.
No Stripe credentials/accounts were contacted. Live email delivery, production
deployment and external iframe behavior are not browser-verified. Public link
framing is restored to base behavior and covered by request specs.

Task-owned app/database containers, anonymous node dependency volume and Docker
network were removed after verification. No task-owned services or browsers
remain running. Logs, temporary browser script and screenshots remain in the
worktree's ignored `tmp/` directories for lead review.
