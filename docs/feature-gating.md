# Feature gating — how EsignCenter decides who gets what

This document explains, in plain English, how the app decides which features a
free, paid, internal or operator account may use, and where each decision is
enforced. Section 1 is the architecture (Session 3, Phase B). Section 2 — the
classification of every leftover `Docuseal.multitenant?` branch — is added by
Phase C of the same session.

## 1. Entitlement architecture

### 1.1 The idea in one paragraph

There are three plans: **free**, **paid** and **internal**. A small list says
which features are paid-only and which are hidden from everyone. Every place in
the app that could switch on a paid feature asks that list — "may this account
use webhooks?" — and refuses when the answer is no. The refusal happens on the
server, so hiding a button is never the only protection: a free account that
posts the request by hand is refused just the same, and a test proves it for
every row of the matrix.

### 1.2 Which plan is an account on? (`lib/plans.rb`)

`Plans.key_for(account)` answers `free`, `paid` or `internal`:

- **Internal** and **operator** accounts (the platform's own accounts) are
  always on the internal plan — they have every surface, they are not
  customers. "Operator has every surface" is how the plan reads it.
- A **customer** account is paid only when it carries a `plan_stub` account
  setting with the value `paid`. A testing child inherits its parent's answer,
  the same way it inherits every other account setting. No row means free.

This is a **stub**. Real plans and billing arrive in Sessions 5 and 6. Session 5
replaces the body of `Plans.key_for` with the real subscription model — that is
the one and only seam — and must re-run `spec/golden/gating_spec.rb` unmodified
to prove nothing else needs to change. Until then, for manual testing on the
dev stack:

```
bundle exec rake "plans:stub[ACCOUNT_ID,paid]"   # make a customer account paid
bundle exec rake "plans:stub[ACCOUNT_ID,free]"   # back to free (removes the row)
```

There is deliberately no screen to set this; the operator console (Session 8)
and real plans (Session 5) own that.

### 1.3 The matrix as data (`lib/entitlements.rb`)

`Entitlements::PAID_ONLY` lists the rows a free account does not get:

`api`, `mcp`, `webhooks`, `signing_sessions`, `embed`, `conditional_logic`,
`reminders`, `branding_removal`, `custom_email_templates`, `account_smtp`,
`bcc`, `delivery_tracking`.

`Entitlements::HIDDEN` lists what nobody gets in v1, internal accounts
included: `sms`, `bulk_send`, `saml_sso`, `formulas`.

`Entitlements.allowed?(account, feature)` is the single question everything
asks. Hidden features are always "no"; paid-only features are "yes" for paid
and internal plans; a feature name that is not in either list raises an error
(so a typo can never quietly allow something). `Entitlements.require!` is the
same question phrased as "refuse unless allowed" — it raises
`Entitlements::UpgradeRequired`, which the controllers turn into the refusal
shapes below.

`delivery_tracking` is declared here so the pricing page can list it, but its
enforcement (the sent/bounced/opened projection) lands in Session 8; Session 8
owes that row's test.

### 1.4 Abilities (`lib/ability.rb`)

Every signed-in user, whatever their role, gets `can :use, <feature>` for each
paid-only feature their account's plan allows, and an explicit `cannot :use`
for everything else (hidden features included). Views ask
`can?(:use, :embed)`, `can?(:use, :conditional_logic)` and so on. The MCP door
keeps requiring the admin-level `:manage, :mcp` and additionally requires
`:use, :mcp` — role says *who may administer*, plan says *whether the account
has it*.

### 1.5 What a refusal looks like

- **JSON doors** (REST API, MCP, signing sessions, template-builder sessions,
  and any in-app save that sends a JSON body): HTTP `403` with
  `{ "error": "This feature requires a paid plan" }`. The English text is the
  constant `Entitlements::REFUSAL_MESSAGE`, like the other API errors.
- **Browser forms**: sent back to the page they came from with the alert
  "This feature requires a paid plan" (locale key
  `this_feature_requires_a_paid_plan`, translated for every language). Nothing
  is saved.

The decision is always about the **acting user's account** — never about
anything the request claims about itself.

Two rules soften the edges for downgraded accounts (decision D43 — a downgrade
never purges):

- **Clearing is always allowed.** A free account may blank out a BCC address,
  reminder schedule or email template it can no longer set. Only a non-blank
  value is refused.
- **Existing data stays but goes inert.** Webhook URLs, the remove-branding
  flag and reminder schedules saved while paid are kept; they simply stop
  doing anything until the account is paid again. Conditions already on a
  template keep evaluating for signers — the check runs when fields are
  *saved*, never at signing time.

### 1.6 Where each row is enforced

| Matrix row | Where the server refuses | What a free account sees |
|---|---|---|
| REST API tokens | `Api::ApiBaseController#authenticate_user!` → `refuse_unentitled_token_account!` — only when the request authenticated with `X-Auth-Token`. The same `/api/*` endpoints keep working over the browser session, because the in-app builder and dashboard use them. | 403 JSON, existing tokens included |
| MCP tokens | `McpController#require_mcp_entitlement!` (`can?(:use, :mcp)`), before the enable-MCP toggle is even consulted | 403 JSON |
| Webhooks | `WebhookSettingsController` create/update/resend require `:webhooks`; `WebhookUrls.for_account_id` returns no URLs for an unentitled account, so nothing is ever enqueued for it (stale rows included) | Redirect + alert; no deliveries |
| Embedded signing sessions | `Api::SigningSessionsController` requires `:signing_sessions` for token and session callers alike (independent of the generic token refusal) | 403 JSON |
| Embedded template builder | `Api::TemplateBuilderSessionsController` requires `:embed` | 403 JSON |
| Conditional logic | `Templates::AssertEntitledFields` on every path that assigns incoming fields: builder save (`TemplatesController#update`), embedded builder save (`EmbedTemplateBuilderController#update_template`), `Api::TemplatesController#update`, `Templates::CreateFromApi` (API template create, signing sessions, builder sessions) and `Templates::Clone` when fields come from another account's template | 403 JSON; template unchanged |
| Formulas (hidden) | Same check, refused for everyone including internal | 403 JSON for all plans |
| Automatic reminders | `NotificationsSettingsController#create` for the `submitter_reminders` setting; `Submitters::ScheduleReminders.call` schedules nothing for an unentitled account | Redirect + alert; no reminder jobs |
| Branding removal | `PersonalizationSettingsController#create` for the `remove_branding` flag; honored by `Accounts.branding_removed?` in the email footer (`shared/_email_attribution`) and the signing-page footer (`shared/_powered_by`). Only the "Powered by" / "Sent using" wording goes away — the DocuSeal attribution link and Source link always render (AGPL §7(b)) | Redirect + alert; branding stays on |
| Custom email templates | `PersonalizationSettingsController#create` for the four account-level email templates; `TemplatesPreferencesController#create` for per-template email subject/body (invitation, reminder, documents copy, completed notification, per-signer copy) | Redirect + alert |
| Per-account SMTP | `EmailSmtpSettingsController#create` (as a before-action, so the refusal is not swallowed by the controller's own error handling) | Redirect + alert; no SMTP row |
| BCC / documents-copy address | `NotificationsSettingsController#create` for `bcc_emails`; `TemplatesPreferencesController#create` for a template's `bcc_completed` | Redirect + alert |
| Delivery tracking | Declared; enforced in Session 8 | — |

Signer-page copy (`form_completed_button`, `form_completed_message`), policy
links and the logo upload stay free.

### 1.7 The proof

`spec/golden/gating_spec.rb` has one example per row. Each drives the real
HTTP endpoint three times: a free customer is refused **and** the database /
job queue is shown unchanged; an internal account succeeds; a paid customer
succeeds. It also proves the operator kind resolves to the internal plan, that
SMS is hidden even from internal accounts, and that an unknown feature name
raises. The only place the spec says "paid" is the account factory's `:paid`
trait (`spec/factories/accounts.rb`), which today writes the stub row —
Session 5 re-points that trait, not the spec.

`spec/lib/plans_spec.rb` and `spec/lib/entitlements_spec.rb` cover the two
modules directly, including the "clearing is always allowed" rule and the
refusal copy in every declared language.

### 1.8 What later sessions owe

- **Session 5** — replace the body of `Plans.key_for` (and the `:paid` factory
  trait) with the real subscription model; re-run `spec/golden/gating_spec.rb`
  unmodified.
- **Session 6** — wire the upgrade call-to-action (Phase C's
  `shared/_upgrade_cta`, `data-upgrade-cta`) to the real Checkout link.
- **Session 8** — enforce `delivery_tracking` when the EmailEvent projection
  lands, with its row assertion added to the golden spec.
