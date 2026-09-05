# The public pages: landing, pricing and trust

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
- `/terms` and `/privacy` are the legal pages (see `docs/legal.md`).

All four share one layout, `app/views/layouts/marketing.html.erb`. The views live
in `app/views/marketing/`; the controller is `MarketingController`.

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
sign-up links while registration is off) and `spec/system/marketing_spec.rb`
(no sideways scrolling at 390 px and 1440 px, the keyboard menu, the
reduced-motion rule, screenshots in `tmp/screenshots/`).
