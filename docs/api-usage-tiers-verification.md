# D79 implementation and verification

Status: done. Implementation commit `9f60554c` on `feature/api-usage-tiers`; no push, PR, deployment,
or Stripe network operation was performed.

## Implementation

- `lib/plans.rb`, `lib/quotas.rb`, `lib/quotas/limits.rb`, subscription/override
  models and `20260923120000_add_api_usage_tiers.rb`: Business, billing-account
  API allowances, durable first-signer/source metering, lineage, overrides,
  retained pack capacity, and monthly warning idempotency.
- Submission creation services, signing sessions, API error handling, start
  forms, hosted embed scripts and resubmission controllers: API/embed/MCP
  refusal at allowance; ordinary in-app sending and existing signers continue.
  Public share embeds retain their source and show live pause/resume states.
- `lib/stripe_billing*`, `lib/billing_lifecycle.rb`, billing controllers/routes,
  operator revenue and `lib/tasks/stripe.rake`: subscription-item mapping,
  prorated plan changes, recurring packs, correct Business seat changes,
  invoice totals, configuration checks and optional price provisioning.
- Billing/API settings views, `lib/pricing_matrix.rb`, marketing/help views,
  quota mailers and `config/locales/api_tiers.yml`: usage meters, purchase
  controls, four pricing columns, Enterprise contact and customer explanations.
- `config/legal/terms.html.erb`, `lib/legal_documents.rb` and the preserved
  September 23 Terms archive: versioned disclosure of the API-channel exception.
- Golden/request/library specs cover metering, creation doors, pause/resume,
  warning retries/rollover, authorization, Stripe items, billing actions,
  operator overrides/revenue, entitlements and pricing/settings/legal copy.

## Implementation defaults beyond D79

1. Initial Checkout remains Paid. A trial can switch to Business immediately;
   it receives Business's included allowance. API packs are sold only after the
   trial ends, because Stripe trial items have no immediately billable prorated
   remainder. The settings page explains this restriction.
2. Pack controls accept a target recurring quantity of 0–9999. Plan changes
   require an active/trialing subscription; pack changes require active.
   Manual grants, children, pending deletion, cancellation/dunning, pending
   payments and externally scheduled subscriptions cannot use these controls.
3. Pack reduction changes Stripe's recurring quantity without proration while
   preserving purchased capacity locally until the current renewal date.
   Re-adding still-covered packs does not charge twice. Adding beyond retained
   capacity invoices only the new increment, with access granted after payment.
   UTC usage reset remains independent of Stripe's renewal date.
4. An operator API override is absolute, including packs: blank inherits,
   `0` blocks new automation, and `-1` means unlimited. It never grants Free API
   entitlement. An explicit zero allowance produces no percentage emails.
5. New API corrections retain the original source and face the creation cap,
   even if their lineage already counted. D74's Free completion exemption is
   unchanged. Repeated correction clicks resume the same pending lineage copy.
6. Hosted shared-form embeds and iframe starts are classified as `embed`;
   ordinary top-level shared links remain `link`. Public shared embeds allow
   framing from any site. Private template pages retain SAMEORIGIN and private
   signing sessions/corrections retain their origin allowlist. Clients cannot
   inject the server-owned public-embed marker through API/session payloads.
7. Enterprise links to the existing `/support` contact form. It has no plan key
   or Stripe product. New application locale strings use the existing English
   fallback; marketing and legal pages remain English.
8. Terms advance to `2026-09-24` under `docs/legal.md`'s explicit next-date rule
   for a second revision on the same day; the old text/digest remain archived.

## Deployment setup

Run `bundle exec rails db:migrate` before starting the new app. The migration
adds subscription `plan` (existing rows default to Paid), `api_pack_quantity`,
`retained_api_pack_quantity`, `retained_api_pack_until`, and override
`api_completions_per_month`.

Keep `STRIPE_PRICE_ID` as the existing $10/month seat price. Optionally create
and configure distinct monthly USD prices:

- `STRIPE_BUSINESS_PRICE_ID`: $49/month Business base, including one seat.
- `STRIPE_API_PACK_PRICE_ID`: $10/month API pack, including 50 completions.

`bundle exec rake stripe:api_prices` creates/finds these by stable lookup keys;
`bundle exec rake stripe:check` verifies them. These contact Stripe and were
**not run**. Customer Portal quantity editing must remain off. Missing optional
IDs do not break existing Paid configuration; corresponding purchases are
unavailable with explanatory copy. Invalid/reused price IDs fail validation.
Keep optional IDs configured after selling their products.

## Verification environment

Used the existing development image `esigncenter-app:latest`, mounted only this
worktree into task-owned `esign-api-tiers-app`, and created a fresh task-owned
PostgreSQL 18 instance. Four locked gems missing from the image were installed
inside this disposable container. No live/local-production database was used.

Docker's shared disk had no space for PostgreSQL initialization, so its task
instance used a 1 GB tmpfs. Browser temporary files used the host-mounted
`/app/tmp` after the first Chromium process died on the full container disk.
Two isolated databases allowed independent runs: `docuseal_test` and
`docuseal_api_ui_test`. The latter URL below uses disposable local credentials.

## Test commands and results

Broad quota/request run:

```sh
docker exec esign-api-tiers-app bundle exec rspec \
  spec/golden/api_usage_tiers_spec.rb spec/golden/quota_spec.rb \
  spec/golden/gating_spec.rb spec/golden/operator_console_spec.rb \
  spec/lib/plans_spec.rb spec/lib/entitlements_spec.rb spec/requests
```

**516 examples, 4 failures initially.** Fixed Free feature-error precedence,
source-preserving correction idempotency, and the intentionally changed plan-key
expectation. The expensive existing quota cases, operator cases and remaining
requests passed. All affected cases were rerun with the following final command:

```sh
docker exec esign-api-tiers-app bundle exec rspec \
  spec/golden/api_usage_tiers_spec.rb spec/golden/gating_spec.rb \
  spec/lib/plans_spec.rb spec/lib/entitlements_spec.rb \
  spec/requests/start_form_authorization_spec.rb \
  spec/requests/start_form_email_2fa_send_spec.rb \
  spec/requests/start_form_email_verification_required_spec.rb \
  spec/requests/signing_sessions_spec.rb spec/requests/embed_scripts_spec.rb
```

**167 examples, 0 failures.** Existing D42 quota expectations and feature refusal
assertions were preserved; Business plan keys and pricing columns intentionally
extend their prior enumerations.

Billing/Stripe/seat/operator-revenue run:

```sh
docker exec -e TMPDIR=/app/tmp \
  -e DATABASE_URL=postgresql://postgres:postgres@esign-api-tiers-db/docuseal_api_ui_test \
  esign-api-tiers-app bundle exec rspec \
  spec/golden/api_billing_spec.rb spec/golden/billing_page_spec.rb \
  spec/golden/stripe_spec.rb spec/golden/seats_spec.rb \
  spec/golden/operator_console_spec.rb:1350
```

**420 examples, 0 failures.** Earlier development runs were 394/14 failures and
394/1; all were corrected. Existing Stripe check coverage now accepts `SKIP`
only for absent optional prices, while continuing to require the Paid checks.

Pricing/settings/legal/help/usage and related system tests:

```sh
~/.local/bin/box-lock run --label esign-api-tiers-ui-checks -- \
  docker exec -e TMPDIR=/app/tmp esign-api-tiers-app bundle exec rspec \
  spec/golden/api_usage_settings_spec.rb spec/golden/marketing_spec.rb \
  spec/golden/legal_spec.rb spec/golden/help_spec.rb \
  spec/golden/usage_page_spec.rb spec/system/billing_settings_spec.rb \
  spec/system/api_settings_spec.rb
```

**102 examples, 0 failures.**

Final gates:

```sh
~/.local/bin/box-lock run --label esign-api-tiers -- \
  docker exec -e TMPDIR=/app/tmp esign-api-tiers-app bundle exec rake gates:all
```

Isolation, account-kind, branding, RuboCop, ERB lint, ESLint and Brakeman pass.
RuboCop: **781 files, 0 offenses**. ERB: **474 files, 0 errors**.
Brakeman: **0 errors, 0 security warnings** (7 existing ignored warnings).
Development gate failures were fixed without changing lint rules or exclusions.
`git diff --check` passes.

## Browser evidence and limits

The evidence command used:

```sh
~/.local/bin/box-lock run --label esign-api-tiers-browser -- \
  docker exec -e TMPDIR=/app/tmp/api-tiers/browser-tmp \
  -e DATABASE_URL=postgresql://postgres:postgres@esign-api-tiers-db/docuseal_api_ui_test \
  esign-api-tiers-app bundle exec rspec tmp/api-tiers/browser_spec.rb --format progress
```

Sol collected desktop 1440×1000 and phone 390×844 screenshots with Cuprite under
the box lock, using the isolated UI database and ignored temporary script
`tmp/api-tiers/browser_spec.rb`. The run's **4 examples pass**. Screenshots are
at `tmp/api-tiers/screenshots/`:

- `pricing-{1440,390}.png`, `enterprise-contact-390.png`.
- `billing-business-{configured,unconfigured}-{1440,390}.png`.
- `api-business-390.png`, `billing-invalid-packs-390.png`.
- `billing-free-{1440,390}.png`.

Observed interactions: Enterprise opens Support; API meter navigates to Billing;
invalid pack quantity produces the server error; unavailable products hide their
purchase forms; Free displays zero API capacity. Page overflow checks pass.
Screenshots exposed an active Business badge saying Paid; both badge and card
were corrected and recaptured. No separate loading state is introduced by these
server-rendered pages. The empty-usage, unavailable-product and error states are
included. Screenshots were opened for inspection; no Opus/Fable visual reviewer
was available in this runtime.

The entire repository suite was not run. Actual Stripe account provisioning,
real card/proration/3DS flows, live delivery of email and production deployment
were not tested. Stripe behavior is verified with captured-shape fixtures and
WebMock. Cross-site iframe cookie/CSRF behavior was not browser-tested; existing
protections remain unchanged, while framing and private-origin boundaries have
request coverage. No services are intentionally left running after cleanup.
