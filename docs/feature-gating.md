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
- A **customer** account is paid while its subscription row
  (`AccountSubscription`, one per account) is in a paid **access state**:
  `trialing`, `active`, `canceling` (cancels at period end, still paid until
  then) or `past_due` (renewal late, not yet given up on). `suspended` and
  `cancelled` read as free, and so does having no row at all.
- A downgrade never deletes the row (D43): it flips `access_state` and leaves
  everything else — settings saved while paid stay in place but go inert.
- **Children follow their parent.** An account that exists as another
  account's testing child or linked "team" account is billed through that
  parent (`Plans.billing_account`), so the parent's subscription covers it and
  the parent's kind decides its plan. Usage counts (docs/quotas-and-limits.md)
  roll up to the same billing account.
- `Plans.seats_for(account)` is how many people may be in the account: one on
  free, the subscription's `quantity` on paid, unlimited on internal.

Session 6 fills the subscription row's Stripe columns and drives
`access_state` from Stripe webhooks. Until then the operator sets plans by
hand on the dev stack or in production:

```
bundle exec rake "plans:grant[ACCOUNT_ID,SEATS]"   # paid, SEATS seats (status "manual")
bundle exec rake "plans:revoke[ACCOUNT_ID]"        # back to free; the row stays
```

Both refuse internal and operator accounts. There is deliberately no screen
to set this; the operator console (Session 8) and Stripe (Session 6) own it.

### 1.3 The matrix as data (`lib/entitlements.rb`)

`Entitlements::PAID_ONLY` lists the rows a free account does not get:

`api`, `mcp`, `webhooks`, `signing_sessions`, `embed`, `conditional_logic`,
`reminders`, `branding_removal`, `custom_email_templates`, `account_smtp`,
`bcc`, `delivery_tracking`.

`Entitlements::HIDDEN` lists what nobody gets in v1, internal accounts
included: `sms`, `bulk_send`, `saml_sso`, `formulas`. "Hidden" means the
surface is not offered, and where a server path exists it is refused; bulk
send is the exception — the list-import tab is hidden in the UI, but sending
one submission to several recipients over the API or the send dialog is not
blocked (decision 13).

`Entitlements.allowed?(account, feature)` is the single question everything
asks. Hidden features are always "no"; paid-only features are "yes" for paid
and internal plans; a feature name that is not in either list raises an error
(so a typo can never quietly allow something). `Entitlements.require!` is the
same question phrased as "refuse unless allowed" — it raises
`Entitlements::UpgradeRequired`, which the controllers turn into the refusal
shapes below.

`delivery_tracking` is enforced in the signer event-log modal, newly generated
audit PDFs, API event arrays and account-export event counts. Free accounts
keep ordinary signing evidence but tracking rows are filtered out on the
server; the modal shows an upgrade line. Previously signed PDFs are not rewritten. Postmark events are still recorded for
every account so abuse protection works on every plan.

### 1.4 Abilities (`lib/ability.rb`)

Every signed-in user, whatever their role, gets `can :use, <feature>` for each
paid-only feature their account's plan allows, and an explicit `cannot :use`
for everything else — including the hidden features, which no plan ever
unlocks. Views ask
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
- **Hidden features** (SMS, bulk send UI — see 1.3 — SAML SSO, formulas) are not on any
  plan, so their refusal never promises an upgrade: the JSON error is
  `Entitlements::UNAVAILABLE_MESSAGE` ("This feature is not available") and
  the browser alert is the `this_feature_is_not_available` key. Both rescue
  handlers pick the wording from the refused feature
  (`Entitlements.refusal_message` / `Entitlements.refusal_alert`).

The decision is always about the **acting user's account** — never about
anything the request claims about itself.

Two rules soften the edges for downgraded accounts (decision D43 — a downgrade
never purges):

- **Clearing is always allowed.** A free account may blank out a BCC address,
  reminder schedule or email template it can no longer set. Only a non-blank
  value is refused.
- **Existing data stays but goes inert.** Webhook URLs, the remove-branding
  flag, reminder schedules, a pinned SMTP server, custom email copy and BCC
  addresses saved while paid are kept; they simply stop doing anything until
  the account is paid again. The switch-off happens where each one is *read*:
  `MailConfigs.resolve` skips an unentitled account's pin (mail falls through
  to the platform default), the mailers read custom subject/body through
  `Accounts.custom_email_config` / `Accounts.custom_email_copy` (nil for an
  unentitled account, so the default copy renders), the completion job
  collects no BCC addresses, a reminder job already in the queue sends
  nothing (`SendSubmitterInvitationReminderEmailJob`), and a webhook job
  already in the queue makes no request and records nothing
  (`SendWebhookRequest.call`).
- **In-flight signing keeps its entitlements; account-level conveniences do
  not.** The distinction in D43: a document that is out for signature keeps
  working exactly as sent — conditions already on a template keep evaluating
  for signers, submissions created while paid stay open, links keep working.
  What stops at downgrade is the account's own paid conveniences around that
  signing: per-account SMTP, custom email copy, BCC, reminders and webhooks.
  Nothing is deleted; it all comes back when the account is paid again.
- **Saving a template you built while paid still works.** The conditional-
  logic check compares the incoming fields with the persisted template and
  refuses only a condition or formula the save *introduces*; renaming a field
  on a template that already carries conditions is fine, adding a new
  condition is not, and removing one is always allowed. A clone is a new
  template, so cloning a conditional template needs the entitlement (and a
  template with a formula field cannot be cloned by anyone).

### 1.6 Where each row is enforced

| Matrix row | Where the server refuses | What a free account sees |
|---|---|---|
| REST API tokens | `Api::ApiBaseController#authenticate_user!` → `refuse_unentitled_token_account!` — only when the request authenticated with `X-Auth-Token`. The same `/api/*` endpoints keep working over the browser session, because the in-app builder and dashboard use them. | 403 JSON, existing tokens included |
| MCP tokens | `McpController#require_mcp_entitlement!` (`can?(:use, :mcp)`), before the enable-MCP toggle is even consulted | 403 JSON |
| Webhooks | `WebhookSettingsController` create/update/resend, `WebhookEventsController#resend` (event resend; the Resend button is only offered to an entitled account), `WebhookPreferencesController#update` (event toggles) and `WebhookSecretController#update` (secret header) require `:webhooks` — every write; viewing and deleting a URL stay open so a downgrade never blocks cleanup. `WebhookUrls.for_account_id` returns no URLs for an unentitled account, so nothing is ever enqueued for it (stale rows included), and both `SendWebhookRequest` and `SendTestWebhookRequestJob` make no request when the row's account is unentitled at delivery time | Redirect + alert; no deliveries |
| Embedded signing sessions | `Api::SigningSessionsController` requires `:signing_sessions` for token and session callers alike (independent of the generic token refusal) | 403 JSON |
| Embedded template builder | `Api::TemplateBuilderSessionsController` requires `:embed` to mint a builder token, and `EmbedTemplateBuilderController#require_embed_entitlement!` requires it again on every builder-token request — a token minted while paid stops working the moment the account is downgraded, not up to 24 h later | 403 JSON; the iframe page itself shows a short "requires a paid plan" notice |
| Conditional logic | `Templates::AssertEntitledFields` on every path that assigns incoming fields: builder save (`TemplatesController#update`), embedded builder save (`EmbedTemplateBuilderController#update_template`), `Api::TemplatesController#update` (all three against the persisted template as baseline — only *introduced* conditions are refused), `Templates::CreateFromApi` (API template create, signing sessions, builder sessions) and every `Templates::Clone` (own account included; a clone is a new template). Per-submission field overrides (`fields[].preferences.formula` on `/api/submissions`, `/api/submitters`, signing sessions; conditions are template-level only — no submission endpoint carries them) run the same check in `Submissions::CreateFromSubmitters` | 403 JSON; template unchanged |
| Formulas (hidden) | Same check, refused for everyone including internal | 403 JSON for all plans |
| SMS (hidden) | `Submitters.normalize_preferences` — the one seam every submission/submitter path funnels through — refuses a requested `send_sms` before anything is stored, HTML and API alike | Redirect + alert / 403 JSON "This feature is not available" (hidden features never say "paid plan") |
| Automatic reminders | `NotificationsSettingsController#create` for the `submitter_reminders` setting; `Submitters::ScheduleReminders.call` schedules nothing for an unentitled account | Redirect + alert; no reminder jobs |
| Branding removal | `PersonalizationSettingsController#create` for the `remove_branding` flag; honored by `Accounts.branding_removed?` in the email footer (`shared/_email_attribution`) and the signing-page footer (`shared/_powered_by`). Only the "Powered by" / "Sent using" wording goes away — the DocuSeal attribution link and Source link always render (AGPL §7(b)) | Redirect + alert; branding stays on |
| Custom email templates | `PersonalizationSettingsController#create` for the four account-level email templates; `TemplatesPreferencesController#create` for per-template email subject/body (invitation, reminder, documents copy, completed notification, per-signer copy); `SubmissionsController#create` when the send dialog asks to save its message onto the template (`save_message=1`). Read-time: the mailers show default copy to an unentitled account. The reminder wording is read too: `SendSubmitterInvitationReminderEmailJob` asks `SubmitterMailer.invitation_email(submitter, reminder: true)`, which reads the wording in one order, most specific first, subject and body each falling through it on their own: (1) this template's `invitation_reminder_email_subject/body`, (2) the account-level `submitter_invitation_reminder_email` row, (3) the invitation copy of this send — the ad-hoc message typed into the send dialog, then the per-signer copy, then this template's `request_email_*`, (4) the account-level `submitter_invitation_email` row, (5) the stock default. The account-wide reminder wording therefore beats a template's own SIGNATURE-REQUEST wording, and loses only to that template's own REMINDER wording. An account that is no longer paid gets the stock default whatever its rows say. Both places a customer WRITES that wording are on screen: Settings → Personalization → "Signature request reminder email" for the account-level copy, and the reminder row of a template's Preferences dialog for the per-template copy — each offered exactly like the signature-request email beside it (the form when the plan carries the row, the same upgrade banner when it does not) | Redirect + alert |
| Per-account SMTP | `EmailSmtpSettingsController#create` (as a before-action, so the refusal is not swallowed by the controller's own error handling). Read-time: `MailConfigs.resolve` skips an unentitled account's pin | Redirect + alert; no SMTP row |
| BCC / documents-copy address | `NotificationsSettingsController#create` for `bcc_emails`; `TemplatesPreferencesController#create` for a template's `bcc_completed`; `Submitters.normalize_preferences` for a per-submission `bcc_completed` (HTML send dialog, `/api/submissions`, signing sessions). Read-time: the completion job collects no BCC addresses for an unentitled account | Redirect + alert / 403 JSON |
| Delivery tracking | `SubmissionEventsController#index` filters bounce, complaint, open and click timeline rows unless `Entitlements.allowed?(current_account, :delivery_tracking)`. The shared `SubmissionEvents::TRACKING_TYPES` also filters audit PDFs, both API event serializers, and export event counts. Provider ingestion records events on every plan for abuse protection. | 200 modal; free accounts see an upgrade line and no tracking rows |

Signer-page copy (`form_completed_button`, `form_completed_message`), policy
links and the logo upload stay free. So does *minting* an API token (rotate,
reveal) or an MCP token (create, enable): the matrix row is enforced when the
token is used, at the token doors above, and a token minted by a free account
is simply inert until the account is paid.

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

- **Session 6** — wire the upgrade call-to-action (Phase C's
  `shared/_upgrade_cta`, `data-upgrade-cta`) to the real Checkout link.
- **Delivery tracking is complete** — Postmark events project into the signer
  timeline, with the free/paid/internal assertion in the golden gating spec.

## 2. What happened to the `Docuseal.multitenant?` branches

The app we forked ran in two modes: a hosted cloud (`MULTITENANT=true`) and a
self-hosted install. Dozens of `if Docuseal.multitenant?` branches chose
between the two. EsignCenter runs in exactly one mode — the flag is never
switched on — so every branch was a hidden decision about what customers get.
Session 3 (Phase C) read each one and replaced it with the decision the
entitlement matrix actually makes:

- **customer-ok** — the behaviour is right for every account; the branch is
  gone and that behaviour is simply what the app does.
- **operator-only** — a platform surface; it now asks `operator_access?`
  (the operator's own login with 2FA).
- **paid-only** — a matrix row; the view asks `can?(:use, :feature)` and shows
  the upgrade call-to-action (`app/views/shared/_upgrade_cta.html.erb`) to a
  free account. The server refuses the matching POST regardless (section 1).
- **hidden** — nobody gets it in v1 (SMS, bulk send, SAML SSO, formulas, plus
  cloud-only upsells); the code is deleted, routes answer 404.
- **infra-keep** — pure infrastructure where the flag's value changes
  nothing for a customer; left in place with a one-line justification at the
  site.

The listing below is every occurrence of `multitenant` in `app/`, `lib/` and
`config/` at the start of Phase C (commit `6c08c826`, `git grep -n multitenant
6c08c826 -- app lib config`). Line numbers are from that commit.

### 2.1 Controllers, jobs, mailers, models

| Site | What it guarded | Class | Action |
|---|---|---|---|
| `app/controllers/dashboard_controller.rb:23` | Signed-out visit to `/` redirected to the marketing URL | customer-ok | Redirect and its `before_action` removed; a signed-out `/` renders the landing page (`maybe_render_landing`, unchanged) |
| `app/controllers/mcp_controller.rb:55` | Cloud skipped the per-account "enable MCP" toggle | customer-ok | Branch removed; the account's toggle governs for every plan (the paid-row refusal runs before it) |
| `app/controllers/passwords_controller.rb:16` | Self-hosted cleared "email not found" errors on password reset | customer-ok (protective) | Errors are always cleared: an unknown address gets the same "instructions sent" answer as a known one, so the form never reveals which emails exist |
| `app/controllers/sessions_controller.rb:11` | Cloud redirected an unknown email at sign-in to a sign-up page | customer-ok (protective) | Branch removed. The redirect named a registration route that does not exist here, and it revealed which emails exist; Devise's generic "invalid email or password" is the protective answer (see note below) |
| `app/controllers/submissions_resend_email_controller.rb:14` | Cloud skipped recipients emailed in the last 10 hours on "resend all" | customer-ok (anti-abuse) | Throttle is always on |
| `app/controllers/submitters_controller.rb:53` | Cloud skipped an invitation already sent to that address in the last 4 hours | customer-ok (anti-abuse) | Throttle is always on |
| `app/controllers/submitters_send_email_controller.rb:9` | Cloud refused a second invitation email within 10 hours | customer-ok (anti-abuse) | Throttle is always on ("Email has been sent already") |
| `app/controllers/templates_dashboard_controller.rb:52,54` | Which shared templates a dashboard lists | customer-ok | Self-hosted behaviour kept: linked accounts see their own plus templates shared with everyone (not in test mode); branch removed |
| `app/controllers/timestamp_server_controller.rb:12` | Cloud answered 404 to custom timestamp-server saves | operator-only | **Done (Session 4):** the controller is gated by `require_operator_access!` — everyone else gets the 404. The timestamp authority is platform policy; customer accounts always use `TIMESERVER_URL` |
| `app/jobs/application_job.rb:4` | Job retry policy | infra-keep | Retry policy is unconditional in the shipped configuration; justified at the site |
| `app/mailers/submitter_mailer.rb:271` | Per-account custom email domain | customer-ok | No custom domains in v1: `maybe_set_custom_domain` and `@custom_domain` removed; email links use `EMAIL_HOST` (unchanged fallback) |
| `app/models/submitter.rb:62,71` | Whether deleting a submitter destroys or anonymizes its email events | infra-keep | Session 8 owns the EmailEvent projection and decides; justified at the site |

### 2.2 Views

| Site | What it guarded | Class | Action |
|---|---|---|---|
| `app/views/accounts/show.html.erb:136,159` | Decline / delegate toggles were a cloud upsell | customer-ok | Toggles unconditional for everyone (D30); the disabled-toggle tooltip plumbing removed |
| `app/views/accounts/show.html.erb:239,258` | "Always enforce signing order" and "direct file links" behind a cloud ability | customer-ok | Unconditional (signing order is a core row) |
| `app/views/accounts/show.html.erb:275` | "Build search index" control | operator-only | `operator_access?` alone (already the operator gate; the tenancy half dropped) |
| `app/views/accounts/show.html.erb:287` | Cloud-only "Delete my account" danger zone | hidden | The button was removed; the `DELETE /settings/account` route still answers a hand-built request until Session 7 replaces the flow with the recovery-window deletion |
| `app/views/devise/sessions/new.html.erb:3` | Cloud "select server" picker | hidden | Render removed; the (empty) partial deleted |
| `app/views/email_smtp_settings/index.html.erb:38,53` | SMTP security radios / required from-address | customer-ok | Both unconditional. The page itself is a paid row: `can?(:use, :account_smtp)` shows the form, otherwise the upgrade CTA |
| `app/views/esign_settings/show.html.erb:106` | Custom timestamp-server form | operator-only | **Done (Session 4):** the timestamp-server form, the certificate table, the certificate upload button and the verify-PDF box all render only for `operator_access?`. Every admin still sees the signing preferences on the same page |
| `app/views/notifications_settings/_reminder_form.html.erb:5` | Cloud dropped the 1-hour / 2-hour reminder options | customer-ok | Full duration list for everyone. The reminder section is a paid row: form for entitled accounts, CTA otherwise (`_reminder_banner`); the BCC form likewise (`:bcc`) |
| `app/views/personalization_settings/_documents_copy_email_form.html.erb:36,44` | "BCC recipients" and "send automatically" toggles inside the documents-copy email template | customer-ok | Unconditional inside the form; the whole email-templates section is a paid row (`:custom_email_templates`) with the CTA for free accounts |
| `app/views/personalization_settings/_form_policy_links_form.html.erb:1` | Policy links form hidden in cloud | customer-ok | Wrapper removed (policy links are free) |
| `app/views/shared/_navbar.html.erb:73` | Cloud showed a "create free account" button to visitors | customer-ok | Gated on `Docuseal.registration_enabled?` instead (see note below) |
| `app/views/shared/_settings_nav.html.erb:17` | Email (SMTP) and SMS entries | paid-only / hidden | Email entry shown to everyone who may read the config (page shows the CTA); SMS entry removed. The `ENV['SMTP_ADDRESS'].blank?` guard went with it: it hid per-account SMTP whenever the platform has its own SMTP, which is always true in production |
| `app/views/shared/_settings_nav.html.erb:50` | API entry | paid-only | Shown to everyone (`can?(:read, AccessToken)`); page shows the CTA when the plan lacks `:api` |
| `app/views/shared/_settings_nav.html.erb:57` | Webhooks entry | paid-only | Shown to everyone (`can?(:read, WebhookUrl)`); page shows the CTA when the plan lacks `:webhooks` |
| `app/views/shared/_settings_nav.html.erb:65` | SSO entry | hidden | Removed |
| `app/views/shared/_settings_nav.html.erb:70` | MCP entry | paid-only | Shown to admins (`:manage, :mcp`); page shows the CTA when the plan lacks `:mcp` |
| `app/views/shared/_settings_nav.html.erb:93` | Support channels block | customer-ok | Always rendered |
| `app/views/shared/_settings_nav.html.erb:108` | Running-version badge | operator-only | `operator_access?` |
| `app/views/start_form/completed.html.erb:24`, `submissions_preview/completed.html.erb:25`, `submit_form/completed.html.erb:22`, `templates_share_link/show.html.erb:84` | "Send copy to email" / email-2FA controls assumed mail always works in cloud | customer-ok | `Accounts.can_send_emails?` alone (true whenever mail is configured) |
| `app/views/submissions/_email_form.html.erb:26` | Bulk-send enablement and recipient limit | hidden | `data-bulk-enabled="false"` for all, no `data-limit` (several recipients in one send are never blocked) |
| `app/views/submissions/_send_email_base.html.erb:25` | "SMTP not configured" alert | customer-ok | Shown whenever mail is not configured |
| `app/views/templates/_dropzone.html.erb:8,18` | Google Drive import upsell | hidden | Removed |
| `app/views/templates_preferences/show.html.erb:2` | Whether the API/embed tab is shown | paid-only | Shown to everyone; the tab renders the CTA when the plan lacks `:embed`, the real content otherwise. `templates_code_modal/show` does the same |
| `app/views/users/_form.html.erb:27` | Initial password field when inviting a colleague | customer-ok | Unconditional (the invitation email still goes out; a blank password is randomised) |
| `app/javascript/application.js:284`, `app/javascript/template_builder/import_list.vue:153,160,246` | Cloud truncated bulk imports at 1000 rows | customer-ok | Prop and truncation removed (the bulk surface itself is hidden) |

### 2.3 Routes and configuration

| Site | What it guarded | Class | Action |
|---|---|---|---|
| `config/routes.rb:66` | `timestamp_server` mounted only self-hosted | operator-only | **Done (Session 4):** the route stays mounted for everyone and the controller answers 404 to anyone who is not the platform operator |
| `config/routes.rb:105` | `detect_fields` mounted only self-hosted | customer-ok | Mounted unconditionally. It needs the ONNX model at `tmp/model.onnx`; the embedded builder already exposes `detect_fields` for everyone, so this adds no new dependency |
| `config/routes.rb:127-136` | Legacy blob proxy, custom ActiveStorage disk/direct-upload routes, `multitenant_routes` hook | hidden (dead) | Deleted together with `Api::ActiveStorageBlobsProxyLegacyController` (nothing referenced them; ActiveStorage draws its own routes because `config.active_storage.draw_routes` is true here). The golden spec that listed the legacy controller now lists the live controllers only |
| `config/routes.rb:180` | `search_entries_reindex`, `sms`, `mcp` settings routes | operator-only / hidden / paid-only | Reindex mounted (its controller is the operator gate); SMS route, controller and views deleted (404 for all); MCP mounted for all (page shows CTA) |
| `config/routes.rb:185` | `api` and `reveal_access_token` settings routes | paid-only | Mounted for all (page shows CTA) |
| `config/routes.rb` (`sso` route, not tenancy-guarded) | SAML SSO placeholder page | hidden | Route, controller and views deleted (404 for all) |
| `config/application.rb:26` | `config.active_storage.draw_routes = ENV['MULTITENANT'] != 'true'` | infra-keep | Reads the raw environment variable (not `Docuseal.multitenant?`), always true here; left as is |

### 2.4 lib/

| Site | What it guarded | Class | Action |
|---|---|---|---|
| `lib/accounts.rb:102,129,144` | Signing certificate / trusted certs / timestamp-server resolution | operator-only | **Done (Session 4):** rewritten by account kind — customers sign with the one platform certificate (`lib/platform_certificate.rb`) and their own certificate/timestamp rows are ignored; internal accounts keep their own rows; the operator falls back to the platform certificate. The `CERTS` environment escape hatch is deleted and banned by `rake gates:isolation`. See section 8 of `docs/operations.md` |
| `lib/docuseal.rb:31` | The predicate itself | infra-keep | Stays, never flipped (decision-locked); comment names this document |
| `lib/docuseal.rb:44` | `advanced_formats?` (Word/.doc uploads) | customer-ok | Session 4 decoupled it: now `WordConverter.enabled?` (LibreOffice present and `WORD_CONVERSION_ENABLED` not `false`), for every account — see `docs/word-uploads.md` |
| `lib/docuseal.rb:74` | Fulltext search toggle | infra-keep | Operator toggle already governs (`OperatorConfigs`); the tenancy half is inert |
| `lib/download_utils.rb:38,60` | Default for URL validation | infra-keep | Every caller that fetches a user-supplied URL passes `validate: true` explicitly; justified at the site |
| `lib/replace_email_variables.rb:162` | Per-account custom email domain | customer-ok | Removed (no custom domains in v1) |
| `lib/send_webhook_request.rb:73` | HTTPS/localhost rules for webhook targets | infra-keep | Already unconditional for every customer account (Session 1); justified at the site |
| `lib/submitters/form_configs.rb:21` | Policy links in signer-page config | customer-ok | Always included |
| `lib/tasks/gates.rake:58,60,63` | The gate's own banned patterns | infra-keep | Gate definition (it necessarily spells the word) |
| `lib/templates/image_to_fields.rb:527` | ONNX memory-arena tuning | infra-keep | Justified at the site |

Phase B had already replaced three branches at the lines it was editing, all
customer-ok: `personalization_settings_controller.rb` (policy links allowed
for everyone), `lib/webhook_urls.rb` (webhook fan-out now keyed on the
`:webhooks` entitlement), `email_smtp_settings_controller.rb` (the SMTP
"setup successful" mail is sent for everyone).

### 2.5 Survivors

`grep -rn "multitenant?" app lib config` returns exactly these ten lines, all
infra-keep (the predicate is never true here, so each branch is inert):

| Line | What it is | Why it stays |
|---|---|---|
| `app/models/submitter.rb:63` | `has_many :email_events` dependent policy | Unconditional `:destroy` in the shipped configuration |
| `app/models/submitter.rb:72` | `after_destroy :anonymize_email_events` guard | Never runs here; the events are destroyed with the submitter instead |
| `app/jobs/application_job.rb:4` | Comment | Names the retry policy below as infra-keep |
| `app/jobs/application_job.rb:5` | `retry_on StandardError` guard | The retry policy is unconditional in the shipped configuration |
| `lib/download_utils.rb:46` | Default for `validate:` on `call` | Every caller that fetches a user-supplied URL passes `validate: true` explicitly; justified at the site |
| `lib/download_utils.rb:89` | Default for `validate:` on `conn` | Same |
| `lib/send_webhook_request.rb:97` | HTTPS/localhost rules for webhook targets | `account.customer?` already makes them unconditional for every customer account (Session 1) |
| `lib/docuseal.rb:33` | The predicate itself | Stays, never flipped (decision-locked) |
| `lib/docuseal.rb:73` | Fulltext search toggle | `OperatorConfigs` governs; the tenancy half is inert |
| `lib/templates/image_to_fields.rb:528` | ONNX memory-arena tuning | Justified at the site |

`lib/accounts.rb` no longer reads it (rewritten by account kind in Session 4,
see 2.4), `advanced_formats?` no longer reads it either, and the gate
definition in `lib/tasks/gates.rake` spells the word only as an escaped
regex, so the literal grep does not list it.

### 2.6 Feature switches and the upgrade call-to-action

- **Builder flags** (`templates/edit`, `embed_template_builder/show`):
  `withConditions` = `can?(:use, :conditional_logic)` (the embedded builder
  asks `Entitlements.allowed?` for the template's account); `withFormula` and
  `withPhone` are `false` for everyone. The conditions modal tells a free
  account "This feature requires a paid plan" (and refuses to save). The
  Formula item is not offered to any account, internal included — not in the
  field settings menu, not in the payment price menu, and not in the
  right-click context menu; a legacy formula field keeps a read-only formula icon
  whose modal says the feature is not available and refuses to save.
- **Hidden for everyone**: no SMS or SSO settings routes; the "send SMS"
  controls are gone from the recipient forms and the submission page; the
  bulk "upload list" tab is gone from the add-recipients modal; the Google
  Drive import link is gone from the upload dropzone.
- **Upgrade CTA** (`shared/_upgrade_cta`): one partial (title, "%{feature}
  is available on the paid plan", an "Upgrade plan" button carrying
  `data-upgrade-cta` with a placeholder `#` link until Session 6 wires
  Checkout). Rendered on: API, MCP, Webhooks, Email SMTP, Notifications (BCC
  and reminders), Personalization (email templates and branding removal), the
  template code modal and the template preferences API tab. When a page has
  two gated surfaces (Notifications, Personalization) the second one renders
  the partial's `compact: true` variant — a one-line banner — so two identical
  cards never stack.
- **A full free team**: Settings → Users on a free account whose one seat is
  already taken shows the compact upgrade banner — the heading "All seats in
  use", the line "Upgrade to add more people to this account." and an
  "Upgrade plan" button — where the "New user" button used to be, because that
  button's only outcome was a refusal. A PAID account at its seat count keeps
  the button: there the refusal turns into a priced offer for one more seat.
- **Read-only pages carry no create affordances**: when the account is
  suspended, is scheduled for deletion, or the person's own seat was parked
  read-only by a downgrade, the documents dashboard renders no upload
  dropzone, no Upload button and no Create button — the same
  `can?(:create, Template)` question the buttons already asked, now asked once
  for every drop target. The document and folder CARDS are not drop targets
  either: dropping a file on one uploads a document, so a reader who cannot
  create documents gets a plain card and the browser handles their drop the
  way it handles a drop on any other link — no spinner, no greyed-out card and
  no error. The banner above the page says which of the three it
  is: a failed payment points at the billing page, a suspension we applied
  ourselves points at the support address, a parked seat says to ask an
  administrator. Any write that still gets refused answers with one plain
  sentence — "You don't have permission to do that in this account." — in the
  reader's own language, instead of CanCan's untranslated default.
- **Downgraded SMTP settings**: a per-account SMTP pin saved during a paid
  period is not used on the free plan (`MailConfigs.resolve` skips it) but it
  is not hidden either — Settings → Email SMTP shows the CTA plus a read-only
  summary (host, port, username, from address; never the password) with a
  "Remove SMTP settings" button, so the owner can always see and drop it.
- **Branding removal** now has a screen: Settings → Personalization →
  Branding shows the toggle to an entitled account and the CTA otherwise.
- **The reminder email now has a screen too.** All four account-level email
  templates are offered on Settings → Personalization — signature request,
  signature request reminder, documents copy and completed notification — and
  the template Preferences dialog carries the matching per-template row for
  each. The reminder boxes open on the wording a reminder would actually go
  out with today (the reminder copy if somebody wrote one, otherwise the
  signature-request copy it inherits), so what is on screen is what recipients
  receive. Before this the reminder copy could only be set through the JSON
  API: the personalization page had no box for it and the per-template collapse
  was an empty file.
- **Refusal copy** moved to locale keys with customer-friendly wording:
  `test_mode_is_not_available_on_this_account` (was "Test mode is unavailable
  for customer accounts") and the operator's reindex notice
  `started_building_the_search_index_visit_url_to_check_progress`. The reindex
  *refusal* itself was already a 404 (`not_found`).
- `spec/golden/gating_ui_spec.rb` proves the CTA/real-form split for each
  gated page (free vs internal) and that both attribution points render for a
  free account and a paid account with branding switched off.

Two things worth knowing:

- The navbar sign-up button now follows `Docuseal.registration_enabled?`. The
  registration routes it links to arrive with the signup session; turning the
  flag on before then would make the button reference a missing route.
- The "via phone" tab in the add-recipients modal is still there (a
  phone-only recipient can sign in person); only the SMS sending controls are
  gone.

### 2.7 Phone 2FA and webhook URL safety

Two Session 3 changes that are refusals rather than plan rows:

- **Phone (SMS) 2FA is not offered.** Any API request that sets
  `require_phone_2fa` to a truthy value — `true`, `"true"`, `1`, `"on"`,
  `"yes"` or any other non-blank value that is not an explicit "false" — is
  answered with `422 Phone (SMS) verification is not available. Use
  require_email_2fa instead.` before anything is created or changed
  (`Params::PhoneTwoFactorRejector`, applied to submissions, submitters and
  signing sessions). Explicit false forms (`false`, `"false"`, `0`, `"0"`,
  `"off"`) and blanks are ignored and never stored. The template preferences
  form does not accept the flag at all, so it is stripped from the web form.
  A flag stored before this change behaves as if it were unset — a shared
  template carrying only a stale phone flag opens normally — so there is no
  data migration. The public API docs no longer list the property.
- **Customer webhook URLs are checked when they are saved.** A customer
  account can only store a webhook URL that uses `https` and does not point at
  localhost, a link-local address or a cloud metadata host; the form answers
  "Webhook URL must use https" (or "…must not point at localhost or a
  private/metadata address"). Internal accounts keep their `http://localhost`
  URLs for self-hosted development. The check runs only when the URL is new
  or changed, so a legacy row with an unsafe URL still saves its events and
  headers; at delivery time such a row records a terminal error and is never
  retried (`SendWebhookRequest`).
