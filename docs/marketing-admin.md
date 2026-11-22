# The private marketing page (/admin)

Plain English first: one private page that shows how the marketing is doing —
website visits, sign-ups and paid plans, the social channels, and the outreach
the Mac jobs send. It is for the people who run the marketing, and for the
Friday review. It is not a customer feature and it is not the operator console
(`/operator`), which is about accounts.

## 1. Who can open it

- The address is **`/admin`**.
- It opens for a **signed-in user whose email address is on the list and who
  created that login themselves**. The list is the `MARKETING_ADMIN_EMAILS`
  variable on the server, comma-separated, any letter case
  (`dana@example.com, Sam@Example.com`). No address is written in the source,
  because the repository is public. Unset or blank means the page opens for
  nobody.
- **"Created that login themselves" is the proof that they own the mailbox.**
  A login can be made *for* an address by somebody else — an administrator of
  an internal account adds users with a password and no confirmation step, and
  so do the first-run setup page and the provisioning API. So the page asks for
  a login made at a sign-up door: by email at `/sign_up` (which cannot sign in
  until the link mailed to the address is opened), or with Google or Apple
  (which verify the address). The app already keeps a record of exactly that —
  the agreement to the Terms that every self-serve sign-up writes together
  with the user — and that record is what is checked
  (`MarketingAdmin.signed_up_themselves?`). Nothing else needs setting up.
- **Everybody else gets a 404** — signed out, or signed in with any other
  address, including the platform operator. Not a redirect to sign-in and not
  a "forbidden" page: byte for byte the answer a page that does not exist
  gives, so nothing tells a stranger the page is there. The same is true of the
  page's two buttons (`POST /admin/refresh`, `POST /admin/tiktok`).
- The check is on the server (`MarketingAdminAccess`, `lib/marketing_admin.rb`)
  and is about the person who actually signed in: a support session inside the
  listed person's account does not open it.
- One deliberate exception to "always a 404": a platform operator **in the
  middle of a support session** who sends one of the page's two POSTs gets the
  support-session refusal (a 403, written to the audit log), because that rule
  has to see every write a session attempts. The page itself is still a 404
  for them, and an operator already has the source code.
- A listed user sees a **Marketing** link in the top bar. Nobody else does.

- **The session has to have been opened in a way that proves who is using
  it.** Being signed in as a listed user is not that. The app signs somebody in
  to an existing login whenever Google or Apple vouches for the login's
  address, and for an address those companies do not host themselves that mark
  can outlive the person's hold on the mailbox (Google's own guidance says so):
  somebody who once had the address, and still has the Google account they
  made with it, would be signed in as the listed user. So the page opens only
  when *this* sign-in was one of these (`MarketingAdmin::MailboxProof`):
  - the login's **password** (with its two-factor code, where there is one);
  - a **password reset** finished from the link mailed to the address;
  - **Google**, only when Google is the authority for the address: a
    `gmail.com` address, or a Google Workspace account whose domain is the
    address's own;
  - **Apple**, only for an address Apple hosts (`icloud.com`, `me.com`,
    `mac.com`, its private relay).

  Any other session gets the ordinary 404 and is otherwise untouched: a
  Google or Apple sign-in for an address they merely once verified, a session
  the browser restored from "remember me" after it was closed, a proof more
  than 30 days old, and every session that was already open when this shipped.
  Nothing about signing in changes for anybody, and nothing is written into
  the session of anyone who is not on the list.

**Getting access.** Being on the list is not an account. The listed person
signs up at `/sign_up` like anybody else, opens the confirmation email, **signs
in with their email and password**, and goes to `/admin`. The address has to be
confirmed — an unconfirmed address is never let in — so nobody can claim the
page by typing somebody else's email into the sign-up form.

**If `/admin` says "Page not found" and you are on the list:** you are signed
in, but not in a way the page accepts — most often because the browser signed
you back in by itself. Sign out, sign in again with your email and password,
and open `/admin` again.

Two things follow from the proof above, and both are on purpose:

- A login that **somebody else created** for a listed address does not open
  the page, however it is used afterwards: one added by an internal account's
  administrator, the first user made on the setup page, one made by the
  provisioning API, and one that joined a team by invitation.
- If a listed address **already has** a login of that kind, list a different
  address that signs up on its own (an alias is fine), or have that person
  sign up again under an address that has no login yet.

## 2. What it shows

| Section | What is on it | Where the numbers come from |
| --- | --- | --- |
| **Website** | Page views today / 7 days / 30 days, a 30-day chart, top pages, where visits came from, device type, campaign tags, and how often the sign-up page was opened per 100 page views | Counted by this app (section 3) |
| **Product** | New accounts, paid plans now and new this week, documents sent and completed per day | The tables the product already keeps. Customer accounts only; nothing about signers |
| **Channels** | Per app: followers now, change over 7 days, a trend line, views, post count, top posts | YouTube and Meta APIs once a morning (section 4); TikTok typed in |
| **Outreach** | Emails sent, replies, Reddit comments, Facebook group comments, per day | Reported by the Mac jobs (section 5) |

Days on the page are **America/Chicago** days, whatever timezone the server or
the viewer is in.

What three of the Product numbers mean exactly:

- **Documents completed** — a document counts once, when *every* signer has
  finished it, on the day the *last* of them did. One that somebody has not
  signed yet, or declined, does not count. (This is deliberately not the number
  the plan limits use, which charge a document to the month its first signer
  finishes.)
- **Paid plans now** — subscriptions Stripe is running, in a state the app
  treats as paid (a trial, a live subscription, one cancelling at period end,
  one whose renewal is late). Paid access given by hand — `rake plans:grant`
  or the operator console, with an end date or without one — is listed apart
  as "given free" and never counted as bought.
- **New paid plans, last 7 days** — customer accounts whose subscription (the
  trial or the paid plan itself) was *created* in the window, counted even if
  it has ended since: it is a count of plans that started, and "Paid plans now"
  is the count of plans still running. *When* comes from Stripe's own
  "subscription created" event and Stripe's own time for it — not from when our
  row was written, which happens when somebody first opens checkout. *Which*
  has to be the subscription the account actually holds: a duplicate that
  Stripe created for a customer who already had one, and that the app
  cancelled, is not a new plan and is not counted.

Every card has an honest state for "nothing yet": an app with no credentials
says **Not connected yet**, a first day of numbers says **History starts
\<date\>**, and one app failing marks only its own card and keeps its last good
numbers, dated. If a whole section cannot be read, that section says so and the
rest of the page still loads.

## 3. How page views are counted

First-party and on our own server. When a signed-out visitor's browser gets one
of the public pages, the app adds one to a counter for:

> day × page × where the visit came from × campaign tag × device type

That is all that is kept (`marketing_page_counts`). **No cookie is set, no IP
address is stored, no visitor gets an id, nothing is sent to anybody else**, and
the row has no timestamp. The referring address is sorted into one of a dozen
labels (Google, Facebook, Instagram, YouTube, TikTok, Reddit, ChatGPT, LinkedIn,
email, direct, another EsignCenter page, other websites) and then thrown away.
The page counts **page views, not people**: it cannot say how many visitors
there were or what one of them did next.

- **Counted pages:** `/`, `/pricing`, `/trust`, `/trust/subprocessors`,
  `/help` and its articles, `/support`, `/docs/api`, `/terms`, `/privacy`.
- **Not counted:** signed-in users, bots and link previews (by user agent),
  browser prefetches, redirects and error pages, a repeat request answered
  "304 Not Modified" (nothing was sent), `/admin` itself, and anything inside
  the app.
- **Only those pages can ever be stored.** The page a view is filed under is
  matched against a fixed list — the pages above and the help centre's own
  articles (`MarketingAdmin::Traffic::PUBLIC_PATHS`) — and anything else is one
  row, "elsewhere". No address is stored as it arrived, so an invitation link,
  a signing link or whatever a stranger types can never end up in the table,
  and the table cannot be grown from the outside.
- **Adding a new public page:** in its controller, `include MarketingPageViews`
  and `count_marketing_page_views` (optionally `only: %i[...]`), **and add its
  path to `PUBLIC_PATHS`** — until then its views are counted under "Other
  pages".
- **It never slows or breaks a page.** The controller only decides what to
  count; a small middleware (`MarketingPageViewsMiddleware`) writes it once the
  final answer is known. The write has a time budget of a fraction of a second
  (`LOCK_BUDGET_MS`, `STATEMENT_BUDGET_MS`): if the database makes it wait, that
  one view is not counted. And anything in an address the counter cannot make
  sense of means "no origin", never an error page.

**Campaign tags.** A link can carry a tag and the page will show it:

| In the link | Counted as |
| --- | --- |
| `?ct=yt-how-to-sign` | YouTube, tag `yt-how-to-sign` |
| `?ct=tt-…`, `ig-…`, `fb-…`, `rd-…`, `em-…` | TikTok, Instagram, Facebook, Reddit, email |
| `?utm_source=…&utm_campaign=…` | The usual `utm` tags; `ct` wins when both are there |

A tag is kept only if it is lowercase letters, digits, dashes and underscores,
48 characters at most; anything else in the address is ignored. At most 100
different tags are kept per day (the rest are counted together as "All other
tags"), so nobody can grow the table from the outside. The hundredth place is
given out one tag at a time, so two new tags arriving together cannot both
take it.

**"Sign-up page opened"** is how a click on *Start free* is counted without any
script in the browser: the sign-up page being opened by a signed-out person.
The card lists which page the click came from — one of the public pages above,
or "Somewhere else, or opened directly" for everything else, an invitation
link included.

**Sign-ups by tag.** The sign-up form carries the tag in a hidden field, so a
finished email sign-up adds one to that tag's "Signed up" column. It is a
counter: the tag is **not** stored on the account. Two honest limits: the tag
follows a visitor from the page they landed on to the sign-up page only when
that is their next click, and sign-ups with Google or Apple are not counted
against tags.

## 4. The social channels

`MarketingSocialSnapshotJob` runs every morning at 11:00 UTC (5 am Central in
winter, 6 am in summer) and reads each connected app; **Refresh now** on the
page does the same in the background, at most once every 10 minutes for
everybody. One snapshot is kept per app per Chicago day; a second check that
day replaces it.

Credentials are environment variables only. They are sent in request headers,
never in an address, and every error message is scrubbed before it is stored or
shown. A value still starting with `PASTE_` counts as not set.

| App | Variables | Notes |
| --- | --- | --- |
| YouTube | `MARKETING_YOUTUBE_CHANNEL_ID` and `MARKETING_YOUTUBE_API_KEY` | A YouTube Data API v3 key from Google Cloud. Instead of the key, the owner sign-in works too: `MARKETING_YOUTUBE_OAUTH_CLIENT_ID`, `MARKETING_YOUTUBE_OAUTH_CLIENT_SECRET`, `MARKETING_YOUTUBE_OAUTH_REFRESH_TOKEN` (scope `youtube.readonly`) |
| Facebook | `MARKETING_META_PAGE_TOKEN` and `MARKETING_FACEBOOK_PAGE_ID` | A long-lived Page token with `pages_show_list`, `pages_read_engagement`, `read_insights` |
| Instagram | `MARKETING_META_PAGE_TOKEN` (the same one) and `MARKETING_INSTAGRAM_USER_ID` | The Instagram business account linked to that Page; the token also needs `instagram_basic`, `instagram_manage_insights` |
| TikTok | none | No API we may use. Type the numbers in on the TikTok card once a week, from TikTok Studio. Saving twice in a day replaces that day's entry. A number too large to store is refused with a sentence |

An app whose variables are missing is **Not connected yet** and is never
contacted. The job also appears on the operator console's Scheduler tab, where
it can be run by hand.

Four things the cards are careful about:

- **A card keeps its last good numbers for as long as it has any.** If an app's
  checks stop working, the card goes on showing what it last knew, with the
  date (and the year, once it is not this one) — however long ago that was. The
  trend line and the week's change are drawn from the last 60 days only.
- **A change is only shown next to the number it is about.** If the latest
  check came back without views, the card shows a dash (or likes) there and no
  change at all, rather than last week's change in a number it is not showing.

- **"in 7 days" means seven days.** The change is measured against the
  snapshot from seven days before the latest one. When there is none exactly
  there — the history is shorter, a morning's check failed, or TikTok was typed
  in a fortnight apart — the card compares with the nearest earlier snapshot
  and names its date instead ("+30 since Nov 7").
- **Views on Facebook and Instagram are not a running total.** YouTube reports
  the channel's total views and TikTok's total is typed in, so their change
  over a week means something. Meta gives no channel total: the number is
  added up from the newest posts we may read (40 reels, 12 posts), so it also
  moves when an old post drops off that list. Those cards say "recent reels" /
  "recent posts" and show no change for views. Followers are a real total on
  every app.

## 5. Outreach numbers from the Mac jobs

The Mac automations report each day's totals to one endpoint:

```
POST /api/marketing/outreach
Authorization: Bearer <MARKETING_OUTREACH_TOKEN>
Content-Type: application/json
```

```
curl -sS -X POST https://esigncenter.com/api/marketing/outreach \
  -H "Authorization: Bearer $MARKETING_OUTREACH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"day":"2026-11-21","emails_sent":24,"replies":3,"reddit_comments":4,"facebook_group_comments":2}'
```

It answers with what is now stored for that day:

```
{"day":"2026-11-21","mode":"set","counts":{"emails_sent":24,"replies":3,"reddit_comments":4,"facebook_group_comments":2}}
```

- **Fields:** `emails_sent`, `replies`, `reddit_comments`,
  `facebook_group_comments` — whole numbers. Send any or all; a field left out
  is left alone. A number with a fraction (`12.5`) is refused, not rounded.
- **`day`** is optional (`YYYY-MM-DD`); without it, today in Chicago. Up to 60
  days back, and never after today in Chicago — a job running just after
  midnight UTC must not send the UTC date.
- **`mode`** is optional. `"set"` (the default) **replaces** the day's number,
  so a job can safely send the same totals twice. `"add"` adds to it, for a job
  that reports each thing as it happens:
  `-d '{"mode":"add","reddit_comments":1}'`.
- **Answers:** `200` stored, `401` missing or wrong token, `422` with an
  `error` sentence when a value is wrong, `400` when the body is not a JSON
  object, and `404` while `MARKETING_OUTREACH_TOKEN` is not set — the endpoint
  does not exist until it is.

Make the token long and random (`openssl rand -hex 32`); anything under 24
characters is treated as not set. Keep it on the Mac the same way the other
automation secrets are kept, and never put it in a link.

## 6. Environment variables

| Variable | Needed? | What happens without it |
| --- | --- | --- |
| `MARKETING_ADMIN_EMAILS` | Yes, to open the page | The page is a 404 for everyone |
| `MARKETING_OUTREACH_TOKEN` | For the Outreach section | The endpoint answers 404 and the section says "Not connected yet" |
| `MARKETING_YOUTUBE_CHANNEL_ID`, `MARKETING_YOUTUBE_API_KEY` | For the YouTube card | "Not connected yet" |
| `MARKETING_YOUTUBE_OAUTH_CLIENT_ID`, `MARKETING_YOUTUBE_OAUTH_CLIENT_SECRET`, `MARKETING_YOUTUBE_OAUTH_REFRESH_TOKEN` | Only instead of the API key | — |
| `MARKETING_META_PAGE_TOKEN` | For Facebook and Instagram | Both "Not connected yet" |
| `MARKETING_FACEBOOK_PAGE_ID` | For the Facebook card | "Not connected yet" |
| `MARKETING_INSTAGRAM_USER_ID` | For the Instagram card | "Not connected yet" |

None of them is needed for the app to boot, and none changes anything a
customer sees.

## 7. Where the code is

| Thing | File |
| --- | --- |
| The list and the day clock | `lib/marketing_admin.rb` |
| How a session proves who is using it | `lib/marketing_admin/mailbox_proof.rb`, written by `SessionsController`, `PasswordsController` and `OmniauthCallbacksController` |
| The gate | `app/controllers/concerns/marketing_admin_access.rb` (the controller runs it twice; the comment at the top of `marketing_admin_controller.rb` says why) |
| The page | `app/controllers/marketing_admin_controller.rb`, `app/views/marketing_admin/` |
| Website counter | `lib/marketing_admin/traffic.rb`, `app/controllers/concerns/marketing_page_views.rb` (decides), `lib/marketing_page_views_middleware.rb` (writes) |
| Product numbers | `lib/marketing_admin/product.rb` |
| Social checks | `lib/marketing_admin/social.rb`, `lib/marketing_admin/social/`, `app/jobs/marketing_social_snapshot_job.rb` |
| Outreach | `lib/marketing_admin/outreach.rb`, `app/controllers/marketing_outreach_controller.rb` |
| Tables | `marketing_page_counts`, `marketing_social_snapshots`, `marketing_social_statuses`, `marketing_outreach_counts` |

None of the four tables belongs to an account or holds a person, so account
export and account deletion have nothing in them to export or delete.

## 8. Checks

`spec/requests/marketing_admin_sign_in_proof_spec.rb` (which sign-ins open the
page and which leave it a 404), `spec/requests/marketing_admin_spec.rb` (the 404 for everybody off the list,
every card state, Refresh now and its ten-minute limit, the TikTok entry),
`spec/requests/marketing_page_views_spec.rb` (what is and is not counted, bots
and signed-in users skipped, tags, the columns the table may have),
`spec/requests/marketing_outreach_spec.rb` (the token, set and add, refusals),
`spec/lib/marketing_admin/` (the social apps against stand-in servers,
credentials never stored or logged; the product numbers) and
`spec/jobs/marketing_social_snapshot_job_spec.rb`.

Two older registries also had to be told about the page, because each fails
until every new door has been decided about:
`SupportImpersonation::CLASSIFICATION` (`lib/support_impersonation.rb`) and the
write-route lists in `spec/golden/lifecycle_suspension_spec.rb`.

One thing to remember when changing the page's look: the production image
builds the stylesheet from `app/views` and `app/javascript` only, so every CSS
class has to be written in a view. A class named only in
`app/helpers/marketing_admin_helper.rb` would be missing from the shipped CSS;
a spec fails if one appears there.
