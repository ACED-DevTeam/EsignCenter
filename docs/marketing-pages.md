# The public pages: landing, pricing, trust, help, support and the API reference

Plain English first, for anyone who needs to change what the public sees.

## What they are

- **`/`** (signed out) — the landing page: the promise, how it works, the seven
  proof points, who it is for, a pricing teaser, a trust strip. Signed-in
  people land on their dashboard instead (`DashboardController#maybe_render_landing`).
- **`/pricing`** — two plan cards, the full Free-vs-Paid comparison table, the
  small print and a short FAQ.
- **`/trust`** — where data lives, the sub-processor list, the **claim
  register** (every marketing claim with the evidence behind it and, in an ERB
  comment beside each row, the file that proves it) and what we do not claim.
- **`/help`** and **`/help/<slug>`** — the help centre: ten articles anybody can
  read, grouped into sections.
- **`/support`** — the support form: one email to the support mailbox, and a
  receipt.
- **`/docs/api`** — the API reference, with the machine-readable description it
  reads at **`/docs/openapi.json`**.
- `/terms` and `/privacy` are the legal pages (see `docs/legal.md`).

They all share one layout, `app/views/layouts/marketing.html.erb`. The landing,
pricing and trust views live in `app/views/marketing/` (`MarketingController`);
the rest have a controller and a view directory each — `HelpController`,
`SupportRequestsController`, `ApiReferenceController`.

## The help centre

The table of contents is `app/views/help/articles/REGISTRY.yml`: one entry per
article with its title, card blurb, section, "updated" date and reading time,
in the order they appear. `lib/help_center.rb` reads that file and nothing else,
so there is one place to edit. The prose for each article is the plain HTML file
beside it, `app/views/help/articles/<slug>.html.erb`, written with no CSS
classes at all — the typography comes from the `.help-article` block in
`app/javascript/application.scss`, the same discipline as the legal documents.

**No number in an article is typed by hand.** Every cap, price and window is
rendered from the constant that enforces it (`Quotas::Limits`, `StripeBilling`,
`Accounts::Retention` and friends), and `spec/golden/help_spec.rb` scans the
prose of all ten articles and fails on any digit that is not on a tiny list of
non-product numbers. A help page cannot promise a limit the app does not apply.

To add an article: write `app/views/help/articles/<slug>.html.erb`, add its row
to `REGISTRY.yml`, and add its path to `public/sitemap.xml`. The spec fails if a
file has no registry row, a row has no file, or the sitemap and the registry
disagree.

Keep the articles of a section together in `REGISTRY.yml`. The index groups the
cards by section and the "previous / next" links at the foot of an article walk
that same grouping, so a row parked away from its section would send a reader
out of the section they are working through and past the sibling card they had
just seen next to it.

## The support form

`GET /support` renders it and `POST /support` sends exactly one email to
`Docuseal::SUPPORT_EMAIL`, with the sender on `Reply-To`. Nothing is written to
the database: there is no support table, no ticket number and nothing to leak
later. Signed-in visitors get their name and address filled in and fixed, and
their account id, kind and plan travel in the email — derived from the session
on the server, never read from the form.

Three brakes, in this order: five messages an hour from one network; a honeypot
field, which answers with the ordinary receipt and sends nothing, so a script is
never told it was caught; and Cloudflare Turnstile.

The honeypot's field name is deliberately meaningless. A field called `website`
or `url` is one browsers and password managers offer to fill, and a false catch
is the worst way this form can fail: the visitor gets the receipt, believes they
have written to us, and no mail is ever sent.

A signed-in visitor's name and address come from their profile and are shown
read-only, so they are not held to this form's own rules — a profile may carry
no name at all, a longer one than the form allows, or an address with a
character the form's pattern rejects, and none of that should 422 somebody on
the one page that exists to reach a human. A profile with no name falls back to
the address. What the visitor actually types — the topic and the message — is
validated as before.

The page is always a real browser load, never a Turbo visit: it carries its own
widened security policy for the Turnstile widget, and a Turbo visit would paint
it inside the previous document, which still has the ordinary policy — the
widget could never load. `<meta name="turbo-visit-control" content="reload">`
says so, from the page itself, so a link added later cannot forget.

Turnstile is enforced when the instance has both Cloudflare keys and skipped
when it does not — the one place this form differs from sign-up, which fails
closed. Sign-up creates an account and is switched off entirely without the keys
(`RegistrationConfigGuard`); support is how somebody locked out of their account
reaches a person, and a form that refuses everybody because a third-party key is
missing is a form that has failed. Without the keys, no widget and no
third-party script are rendered at all, and the honeypot and the per-IP limit do
the work.

## The API reference

`/docs/api` renders [Scalar](https://github.com/scalar/scalar) from the npm
package `@scalar/api-reference`, bundled through shakapacker as its own pack
(`app/javascript/api_reference.js`) so no other page in the application carries
it. It is served from this origin, never a CDN, because the whole application
runs under `script_src 'self'` — everything in Scalar that would reach off this
origin (its default web fonts, its hosted request proxy and the "try it" client
that needs one, its AI assistant and its MCP integration) is switched off in the
pack.

One thing did have to be handled: Zod, deep inside Scalar, probes for
`new Function` to decide whether it may use a faster code path. The probe is
caught and Scalar works either way, but the browser still reports a blocked
eval. `app/javascript/lib/zod_jitless.js` sets Zod's own `jitless` switch before
Scalar loads, so the probe never happens. `spec/system/api_reference_spec.rb`
proves the result in a real browser: the operation list renders with zero
console errors and zero security-policy violations.

`/docs/openapi.json` is `docs/openapi.json` — the authored document, reviewed
and shipped with the code — with its generic `your-instance.example.com` example
host rewritten to this instance's `APP_URL`, `servers[0]` pointed at this
instance's `/api`, and the contact block pointed at `/support`
(`lib/openapi_document.rb`). The email address in the authored contact block is
dropped rather than repointed: this is a public, indexable, machine-read
endpoint, and an address published there is an address harvested there. It is
built once per process and rebuilt only when the file on disk changes, and
served with `Cache-Control: public, max-age=3600`.

Because the whole document has its host rewritten, the sample files it sends
developers to become URLs on **our** domain. They are real files, under
`public/examples/`, regenerated with `rake api_examples:generate` and committed;
`spec/golden/api_reference_spec.rb` fails if the served document links to
anything on this origin that nothing answers. The description itself has to be
in the deployed image, so the `Dockerfile` copies `docs/openapi.json` explicitly
— the same spec reads the `Dockerfile` and goes red if that line is dropped.

## The sitemap

`public/sitemap.xml` lists every public page — the landing, pricing, trust, the
legal pages, verify, the help centre and its ten articles, the API reference and
the support form — and nothing else, because the rest of the application is
private to an account. It is a static file on purpose: adding a page is a code
change, so a generated sitemap would only move the same edit somewhere less
visible. `public/robots.txt` carries the `Sitemap:` line that points crawlers at
it, and `spec/golden/help_spec.rb` fails when the sitemap's help articles and
the registry disagree.

## The pricing table cannot drift from the product

The comparison table is generated from `lib/pricing_matrix.rb`, which reads the
same constants the app enforces: `Quotas::Limits` (every number),
`Entitlements::PAID_ONLY` (which features a free account is refused) and
`StripeBilling::PRICE_PER_SEAT_USD` / `TRIAL_PERIOD_DAYS`. No number is typed
into the page.

When `lib/pricing_matrix.rb` loads it checks that **every** paid-only feature in
the entitlement matrix is named by some row; if one is missing it raises, so the
test suite fails the moment a feature is gated in the app without appearing on
the pricing page. To add a paid feature: add the symbol to
`Entitlements::PAID_ONLY`, then add (or extend) a row in `PricingMatrix.rows`
and its `pricing_row_*` label in `config/locales/i18n.yml`.

## English only

The marketing and legal pages are English-only by decision. Their controllers
wrap every request in `I18n.with_locale(:en)`
(`ApplicationController#with_english`) and the layout declares `lang="en"`, so
somebody whose account is set to French never sees a French-labelled English
page. The `pricing_row_*` keys do carry translations; they are unused on the web
today and harmless.

## The social preview image

`public/og.png` (1200×630) is what Slack, iMessage, LinkedIn and the like show
when a link to the site is pasted. It is a screenshot of a small HTML card,
rendered with headless Chromium inside the dev container. To regenerate it,
write the card to `tmp/og.html` (logo, wordmark, the promise line, indigo accent
on the off-white ground) and run, inside the container:

```
chromium --headless --no-sandbox --hide-scrollbars --disable-gpu \
  --screenshot=/app/public/og.png --window-size=1200,630 file:///app/tmp/og.html
```

`app/views/shared/_meta.html.erb` points `og:image` and `twitter:image` at it.

## Motion and the phone menu

- Sections fade in as they scroll into view (`reveal-on-scroll`) and the hero
  signature draws itself. Both happen only when JavaScript is running and the
  reader has not asked their system for reduced motion; without either, the
  finished page simply shows. A global rule in `application.scss` stills every
  animation under `prefers-reduced-motion: reduce`.
- On a phone the header collapses into a menu button (`marketing-menu`). It is a
  real button: Enter and Space open it, Escape closes it, and it reports its
  state with `aria-expanded`. Without JavaScript the button does nothing — and
  that is fine, because the footer carries every link the menu holds.

## Checks

`spec/golden/marketing_spec.rb` (what the pages say, the matrix coverage, no
sign-up links while registration is off), `spec/golden/help_spec.rb` (the
registry, every article renders, no typed numbers), `spec/golden/support_spec.rb`
(one mail, the three brakes, the account facts) and
`spec/golden/api_reference_spec.rb` (the rewritten description, no placeholder
host, no dropped path).

In a real browser: `spec/system/marketing_spec.rb` (no sideways scrolling at
390 px and 1440 px on all six pages, the keyboard menu, the reduced-motion rule)
and `spec/system/api_reference_spec.rb` (Scalar renders with no console error
and no CSP violation). Both leave screenshots in `tmp/screenshots/`.
