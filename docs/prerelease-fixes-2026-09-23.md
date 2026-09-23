# Prerelease fixes — September 23, 2026

This is a local release candidate. No production environment, account, webhook
subscription, or deployment was changed. Pipeline Pro is excluded from this
release's integration scope at Evan's direction; its integration will be redone.

## Changes

- Webhook delivery applies HTTPS and private-network restrictions to production
  internal accounts as well as customers. DNS answers are checked and the
  connection uses the checked address while preserving TLS hostname validation.
  Both existing HMAC signature headers remain supported.
- Validated downloads from supplied URLs apply the same destination restrictions
  at every redirect. Internal callers that explicitly disable validation retain
  their existing behavior; these checks do not cover operator-trusted timestamp
  endpoints.
- Provisioning requests have a per-IP rate limit. Public CORS responses no
  longer combine wildcard origins with credentialed access.
- Archived templates cannot mint or use preview sessions. Support impersonation
  cannot clone a customer's template into a different account.
- Opening an invitation link is read-only, including already-member links that
  previously released a paid seat on GET. Acceptance and the scheduled sweep
  retain the seat-release behavior.
- Production boot checks require HTTPS, a valid application origin and timestamp
  endpoint, and configured platform email with encryption and certificate
  verification. `bundle exec rake release:preflight` checks the proposed dark
  deploy configuration without printing values; it does not contact providers.
- Terms and Privacy identify **EsignCenter LLC**, **1911 S National Ave STE 104,
  Springfield, MO 65802**, as confirmed by Evan. Both are versioned September 23;
  previous rendered texts remain archived at their original digests. Source links
  point directly to the organization repository. Counsel review is still required.
- Local environment files and agent/plan directories are excluded from Docker
  build contexts. This is preventive hardening, not evidence of a credential leak.
- Historical Stripe webhook captures retain their original API-version metadata;
  the outbound client version remains unchanged and separately tested.

## Consumers

**Commercial-Lending:** local commit `1a1b6d13` handles the provider's actual
completion message, verifies both origin and sending iframe, and returns to the
request list. The signed webhook remains authoritative for persisted status.
Its 64 focused tests and full TypeScript check passed.

**va-claims:** the `form.viewed` subscription fix already exists on its current
branch (`5e250568`). Local commits `6f78ae24` and `26324283` add inventory export
and an idempotent, dry-run-first repair for existing saved subscriptions,
including protection against concurrent account/URL changes. Six configuration
tests, the full TypeScript check, and the backfill's behavioral tests passed.
The repair was also exercised against real EsignCenter `WebhookUrl` models in a
separate synthetic database; it preserved URL, bearer headers and HMAC secrets,
rejected malformed manifests before writing, and made no duplicate changes.
See the consumer's `docs/operations/esign-webhook-viewed-backfill.md` before
applying it to a deployed service.

## Provider verification

All quality gates passed: tenant isolation, explicit account creation, branding,
775 Ruby files, 471 ERB files, JavaScript lint, and Brakeman with zero errors or
active warnings (seven existing ignored warnings remain). Production assets
compiled successfully with six existing webpack warnings.

Synthetic production boot passed; disabling HTTPS refused boot. Positive and
negative preflight runs passed. Focused readiness/email tests passed 30 examples.
The Docker build-context check confirmed local environment and plan files are
excluded.

The final full suite passed **2,495 examples, zero failures, zero pending, and
zero errors outside examples** in **591 seconds (9 minutes 51 seconds)**. The
first run exposed one suspension test that implicitly depended on billing being
enabled; its setup now enables and restores that flag explicitly, preserving
the existing assertions. Its 53 focused examples also passed before the full
rerun. Provider implementation commits: `f8aa910b`, `4744f007`, `29d54e02`,
and `ac566cdc`.

Terms and Privacy returned HTTP 200 at desktop (1280×900) and phone (390×844)
widths. Both displayed the supplied identity/address and current document
version, with no placeholders or horizontal overflow and the correct source
link. Four screenshots and the observed checks are preserved in
`tmp/prerelease-20260923/`, including `legal-browser-evidence.json`. This is
rendering evidence, not Fable design approval; Fable was unavailable.

Local full-suite evidence: `tmp/prerelease-20260923-final.json` and
`tmp/prerelease-20260923/full-suite-final.log`. Quality-gate evidence:
`tmp/prerelease-20260923/quality-gates.log`.

Checks use an isolated PostgreSQL database and Redis, synthetic fixtures, and
stubbed external services. A passing local test cannot establish production
credentials, mail delivery, or webhook reachability.

## Before release

1. Set and check the required Render environment using the updated
   [deployment checklist](render-deploy-checklist.md). Keep registration and
   billing off for the dark deploy. Production configuration has not been
   inspected or changed in this fix session.
2. Complete the existing backup/restore and migration rehearsal, signing-key
   custody, storage, mail, OAuth, Stripe and legal gates in the approved plan
   and [operations runbook](operations.md).
3. After the separately authorized deployment, apply the reviewed va-claims
   subscription repair and run one real signing canary from Commercial-Lending
   and va-claims, covering existing and newly provisioned workspaces.
4. Verify the exact deployed source is public, then enable the launch switches
   only after the applicable gates have evidence.

## Hands-on testing

Test the candidate before release: signup/confirmation, template upload and
field placement, sending, consent and signing on desktop and phone, completed
PDF download/verification, and trial/billing behavior using Stripe test mode.
For each included consumer, verify embedded signing, automatic return to the
app, authenticated callback delivery, final status and document download.
