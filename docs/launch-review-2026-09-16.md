# Launch review — September 16, 2026

## Scope and release decision

Review of the `standalone-saas` branch, starting at `a25c040e`, including automatic
internal-app provisioning, customer SaaS isolation, signing, embedded editing and
previewing, billing, account lifecycle, and role permissions. Changes are local;
no deployment or production account changes were made.

Local review and verification are complete: all 2,417 provider tests and six
consumer tests pass, along with the quality gates and production frontend build.
Recommend deployed staging verification before public launch. Local checks alone
do not establish readiness of the deployed service or its consumers.

## Changes

- Restored template preview sessions and application-provided custom-field
  palettes used by Commercial Lending but absent from this branch. The restored
  paths honor standalone account state and plan rules. Preview consent can open
  the PDF without a sender login, and completing a dry run writes no signing
  records or callbacks.
- Removed palette-editing controls that cannot persist in an embedded editor,
  including the canvas context-menu action. Placing supplied fields remains
  available.
- Corrected three security findings (two high, one medium) with regression
  coverage. Detailed security notes are kept outside the public documentation.
- Expired account exports now show their expired state immediately, instead of
  showing a download that has already stopped working.
- Placeholder Google OAuth configuration no longer exposes a broken sign-in
  button.
- Updated integration documentation and the OpenAPI preview contract. Clarified
  that internal app accounts do not require customer signup, Stripe, or paid
  seats; public customer accounts follow their plan's API entitlement.
- Restored accessible names for compact signer text fields, including character
  boxes. Updated the full signing journeys to follow the current document
  positions while retaining all saved-value and completion assertions.
- Excluded generated local documents, screenshots and compiled assets from
  RuboCop scanning. Application and test source remain checked.

A separate minimal change in `/Users/edockstader/GitHub/va-claims` corrects new
webhook subscriptions from `form.opened` to `form.viewed` and adds a regression
(local commit `5e250568`; not pushed).
Existing saved subscriptions require a deployment/backfill step; this review did
not alter them.

## Consumer compatibility evidence

Commercial Lending source was inspected in `src/core/esign/{client,provisioning,
config,templates}.ts` and `src/app/api/esign/webhook/route.ts`. It automatically
provisions per-organization accounts, stores encrypted returned credentials, uses
`X-Auth-Token`, sends `custom_fields`, calls the preview endpoint, and verifies
`X-Docuseal-Signature` over `timestamp.body`. The legacy signature header remains
supported alongside `X-Esigncenter-Signature`.

VA Claims source was inspected in `lib/docuseal/{client,provisioning}.ts` and its
two webhook route aliases. Provisioning without an idempotency key, multiple
signing origins, disabled provider email/SMS, and its webhook authentication
formats remain supported by the provider contract.

Each app must keep the global provisioning secret server-side. Each resulting
workspace receives its own account token and webhook secret. There is no need
for those app users to register separately as SaaS customers.

## Verification

- Production frontend: `RAILS_ENV=production NODE_ENV=production bundle exec
  bin/shakapacker` passed (76 seconds). Six warnings remain in Scalar's API
  reference CSS/dynamic import and bundle-size guidance; no compilation errors.
- Focused signer/API/embed journeys: 65 examples, zero failures. The PNG prefill
  test now retrieves the served image and completes through the actual signer
  route before checking that the resulting PDF contains the image.
- An initial complete run after the signing fixes finished 2,417 examples with
  one failure. It exposed a fixture creating two platform operators, making the
  certificate lookup nondeterministic; the fixture now seeds one operator before
  creating its certificate. Final rerun results follow below.

- `bundle exec rake gates:all` passed: isolation, account-kind and branding
  checks; 765 Ruby files; 471 ERB files; JavaScript lint; Brakeman with zero
  errors/active warnings. Seven existing ignored warnings were unchanged.
- Explicit ESLint checks of all four changed Vue components passed.
- All 30 platform-certificate tests passed after correcting the fixture.

**Final full suite:** `bundle exec rspec --format progress --format json --out
/app/tmp/launch-review-full-release.json` passed: **2,417 examples, zero failures,
zero pending, zero errors outside examples**, in 15 minutes 15 seconds. The run
used an isolated PostgreSQL database and local Redis; external calls in the
automated suite were blocked/stubbed. It includes the real browser signing
journey from automatic internal provisioning through consent, completion, both
webhook HMAC headers, API document download and cryptographic PDF verification.
The internal workspace had no customer subscription.

Detailed run evidence is in `/tmp/esign-launch-20260916/`: `gates-release-2.log`,
`vue-release.log`, `production-assets.log`, `signing-final.log`,
`certificate-final.log`, `full-release.log`, and `sandbox-webhook-verify.log`.
Machine-readable suite results are in `tmp/launch-review-full-release.json`.

The manual local customer journey completed Stripe's actual sandbox checkout,
returned to the app with a 14-day trial and $10 per seat per month, opened the
customer billing portal, and cancelled the trial there. Stripe cannot deliver to
localhost, so the actual sandbox cancellation event was fetched and relayed to
the local signed webhook endpoint. Its background processor applied it, and the
browser then showed “Your trial ends ...; you will not be charged” and “Nothing —
the trial ends before the first charge.” This validates the local receiver and
processor, not delivery to a deployed public webhook URL. Only a synthetic test
identity and Stripe test card were used; outbound real email was disabled.

VA Claims' targeted `tests/docuseal-config.test.ts` passed: six tests, zero
failures, under Node 22.16.0. Dependencies were installed with the pinned pnpm
version, frozen lockfile and lifecycle scripts disabled; no package/lockfile
changes. The test ran from an isolated directory with a dummy database URL.
Its log is `/tmp/esign-consumer-review-20260916/config-test.log`. A separate
source-contract check also passed against EsignCenter's actual event catalog.

## Before public launch

1. Deploy this provider update before consumer updates, then run one signing
   canary from each deployed app: automatic provisioning, actual-domain iframe,
   signer consent/completion, authenticated callback, downloaded final PDF, and
   the consumer's completion action. Check preexisting internal accounts as well
   as a newly provisioned workspace.
2. Update VA Claims' existing webhook subscriptions to include `form.viewed`.
   Confirm whether the separate historical S31 branch ever provisioned live
   accounts; if it did, audit its older stored idempotency-key format before
   promising recovery of those provisioning requests.
3. Complete the existing [deployment checklist](render-deploy-checklist.md):
   operator signing certificate setup, durable document storage and restore
   drill, mail delivery/bounce handling, public-domain rate limiting, resource
   headroom, and the production Stripe configuration/webhook checks. Repeat the
   sandbox checkout/portal cancellation journey against the deployed service,
   including delivery from Stripe to the public webhook endpoint.
4. Verify public OAuth providers if enabled and complete the plan's legal and
   launch approvals. Enable registration/billing only after the applicable
   launch gates have evidence.

These are deployment verification gaps, not results established by the local
regression suite. See [operations](operations.md) for the existing procedures.

## Cleanup and handoff

Removed the review-only PostgreSQL container, volume and Docker network. The
local browser server and test containers are stopped; other applications were
untouched. The synthetic Stripe sandbox subscription is scheduled to end at the
trial boundary without a charge. No live payments, real emails, production
account changes, pushes or deployments were performed. Test logs remain in the
scratch directories above.

Final session cleanup output:

```text
capped cleanup: nothing left running
sweeper during this session:
  (none)
```
