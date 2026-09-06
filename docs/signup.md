# Self-serve sign-up

How a stranger gets an EsignCenter account, what protects the door, and the
switch that opens it. Everything here is customer-facing behaviour; the
operator side (env variables, boot guard) is in `docs/operations.md` §3.

## 1. Signing up with email and password

1. On the sign-in page the visitor clicks **Create free account** (or opens
   `/sign_up`). The page states the free tier in one line — *Free: 5
   completed documents a month, 1 user* — and asks for a full name, an email
   address and a password (6 characters minimum).
2. A Cloudflare Turnstile check sits in the form. It is usually invisible;
   a suspicious browser gets a short challenge.
3. Submitting creates **one customer account** (named after the person, in
   the timezone their browser reported, in the language the page was shown
   in) with **one admin user**. Nobody is signed in yet.
4. A confirmation email goes out from the platform address. Until the link
   in it is opened the person cannot sign in: the sign-in form answers *You
   have to confirm your email address before continuing.*
5. The "Check your email" page says where the mail went and offers a
   **resend** link (the standard resend form: it answers the same way whether
   or not the address is known, so it cannot be used to discover accounts).
6. Opening the link confirms the address; the person signs in and lands on
   their dashboard.

An address that already has a user is refused with *has already been taken*.
That does reveal the address exists — accepted, because the alternative is a
silent "success" that leaves a real person waiting for a confirmation mail
that never comes.

## 2. Continue with Google

The **Continue with Google** button appears on the sign-in and sign-up pages
when the Google credentials are configured and sign-up is open. Google hands
back a verified email address; then:

- **New address** → a customer account and its admin are created exactly as
  above, except the user is confirmed at once (Google verified the mailbox)
  and given a random password. They can set their own from *Forgot your
  password?* later. Signed in straight away.
- **Existing user, not yet confirmed** → the password on that account is
  replaced with a random one, then the account is confirmed and signed in.
  An unconfirmed account is one nobody ever proved they own: anybody can type
  somebody else's address into the sign-up form, and the password on the
  account would be theirs. Google has just proved the mailbox, so the account
  is kept — but whatever password was on it stops working, and the owner sets
  their own from *Forgot your password?*. No second account is ever created
  for an address that already has a user.
- **Existing confirmed user** → signed in, and their password is left
  alone: they proved the mailbox themselves, so it is theirs to keep.
- **User with two-factor authentication** → sent back to the password form
  with a message: the one-time code is entered there, Google never bypasses
  it.
- **Google says the address is not verified**, or the address is on the
  disposable list, or the exchange with Google fails → back to the sign-in
  page with a plain-English message; nothing is created.

The Google path skips Turnstile (Google already gated the request) but keeps
the per-network limits and the disposable-address blocklist.

Sign-in with Google requires a Google OAuth app. Until that app is published
in Google's console it runs in **Testing** mode: only the test users listed
there can use the button (launch-gate item 4b). Everyone else still has the
email path.

## 2b. Continue with Apple

The **Continue with Apple** button sits next to the Google one, on the same
two pages, and appears when all four `APPLE_OAUTH_*` values are real — see
*Turning the Apple button on* below. Everything after Apple hands back an
address is identical to the Google door: the same new-account rules, the same
adoption of an unconfirmed account, the same two-factor detour, the same
per-network limits and disposable-address blocklist, the same four starter
documents, and the same record of what was agreed to. Apple only differs in
three places.

**1. Apple shares the address once, and only once.** The very first time
somebody authorises us, Apple sends their e-mail address (and, if they leave
it switched on, their name). Every sign-in after that sends an internal
identifier and nothing else — which is fine, because by then the account
exists and we recognise them by their address.

The awkward case is somebody whose first attempt did not finish: they hit the
hourly sign-up limit, used a throwaway address, or the page they clicked from
was showing an out-of-date Terms of Service. Apple now thinks they have
already authorised us, so it sends no address, and there is no account for us
to sign them into. Rather than invent anything, the page tells them what
actually fixes it: on their device, open **Settings → their name → Sign in
with Apple**, remove EsignCenter from the list, and try again — the next
attempt counts as a first authorisation and the address comes through. No
account is ever created without an e-mail address.

**2. The address may be a private relay.** Apple lets people hide their real
address behind a `@privaterelay.appleid.com` forward. That is a genuine,
deliverable mailbox and is stored and used exactly like any other — nothing
in the product treats it differently. It is worth knowing only because a
customer may be puzzled by the address on their own profile page.

**3. Apple answers with a form submission, not a redirect.** Google sends the
browser back to us with an ordinary link; Apple sends it back with a hidden
form that posts from Apple's own website. Two consequences, both handled:
that one address (`/auth/apple/callback`) accepts a post without our usual
cross-site form token, and the session cookie handed out when the button is
pressed is marked so the browser will still send it back on Apple's
submission. Nothing else on the site changes.

### Turning the Apple button on

The button hides itself, and every `/auth/apple/...` address answers *404*,
unless **all four** of `APPLE_OAUTH_CLIENT_ID`, `APPLE_OAUTH_TEAM_ID`,
`APPLE_OAUTH_KEY_ID` and `APPLE_OAUTH_PRIVATE_KEY` hold real values. "Real"
is checked, not assumed:

- a value still starting with `PASTE_` (how the environment file ships every
  unfilled slot) does not count;
- the team id and the key id must be Apple's ten characters;
- the private key must be an actual key (the `-----BEGIN ... PRIVATE KEY-----`
  text of the `.p8` file Apple gives you). A key stored on one line with `\n`
  in place of the line breaks is accepted too, because most hosting panels
  store it that way.

Anything short of that and the button simply is not there; email sign-up and
the Google button are unaffected, and a production boot logs a warning saying
which variables are missing. The Apple Developer steps that produce those four
values are written out in `docs/render-deploy-checklist.md` under launch gate
4b.

## 3. The four abuse guards

| Guard | What it does | Numbers |
| --- | --- | --- |
| Cloudflare Turnstile | Every email sign-up carries a one-time token from the widget; the server asks Cloudflare whether it is genuine. A blank token, a Cloudflare outage or a missing secret all **fail closed** — the form re-renders with *Please complete the verification and try again* and nothing is written. There is no environment bypass; the test suite stubs the HTTP call. | one check per submission, 5 s timeout |
| Disposable-address blocklist | Addresses at throwaway-mail domains (the `valid_email2` list, e.g. mailinator.com) are refused with *Please use a permanent email address*. Sign-up only: an admin may still invite such an address to their own account, and internal provisioning is untouched. The domain list is checked, never DNS. | — |
| Per-network limits | Sign-ups from one IP address are counted — sign-ups, not attempts. On the email path an attempt counts only once the Turnstile check and the form's own checks (a valid, permanent, untaken address; a long enough password) have passed, immediately before the account is written; a typo, a taken address or a failed CAPTCHA never spends the budget, so five mistakes from one office never lock the office out. On the Google and Apple paths only the creation of a new account counts (an existing user signing in with a provider is not a sign-up). Past the limit the form answers *Too many sign-ups from this network* with status 429 and the provider paths return to the sign-in page with the same message. Invitations and sign-in are not counted. Redis-backed like the other velocity limits: if Redis is down the limit is off, never the sign-up. | 5 per hour, 20 per day |
| Per-network attempt ceiling | A second, separate count: every sign-up **attempt** from one IP address, however it ends, and every hit on a Google or Apple `/auth/...` endpoint. Checked first, before anything outbound happens — the Turnstile check is a call to Cloudflare that waits up to five seconds, and the provider callbacks make OmniAuth call Google or Apple, so an attempt anyone can replay for free is a web thread they can hold for free. Past the ceiling the form answers *Too many sign-ups from this network* (429) and the provider endpoints answer 429 with an empty body. Set far above honest use: a whole office behind one address never gets near it. Redis-backed and fails open the same way. | 30 sign-up attempts per hour, 60 provider hits per hour |

## 4. The switch

`REGISTRATION_ENABLED=true` opens sign-up. Anything else keeps it closed:

- `/sign_up`, the check-your-email page, the confirmation resend form and
  every `/auth/...` Google and Apple endpoint answer **404** (empty body).
- The sign-in page shows no *Create free account* link and no Google or Apple
  button; the navbar shows no sign-up button.
- Existing users sign in, reset passwords and get invited exactly as before.

In production the app **refuses to boot** with the switch on and the
Turnstile keys missing (an open door that could never let anyone in). Missing
Google or Apple credentials only hide that button and log a warning.

## 5. Starter templates

A brand-new account is not an empty shelf. The moment a customer account is
created by any self-serve door — the email form, the Google button or the
Apple button — four ready-made documents are put into it in the background:

- **Mutual Non-Disclosure Agreement** — two parties agree to keep each other's
  information private before working together.
- **Freelance Service Agreement** — a client and a freelancer agree the work,
  the fee and the start date.
- **Photo & Video Release** — one person gives permission for photos, video
  and audio of them to be used.
- **Personal Property Bill of Sale** — a seller and a buyer record the item,
  the price and the date it changed hands.

Each one is a real template with its signers and its fill-in blanks already
placed, so it can be sent for signature straight away. Each carries a short
italic line, *Starter template — review before use*: they are sensible
starting points, not legal advice, and they are meant to be edited.

Rules worth knowing:

- Only the two self-serve doors seed. Accepting a team invitation joins an
  account that already exists, so nothing is added; provisioned, internal and
  operator accounts never get them, and neither does an account created from a
  console or a script (a caller with no human in front of it does not need four
  sample documents to look at).
- They are seeded **once**. An account that deletes all four does not get them
  back, and an account that already holds a template of its own is left alone.
- They cost nothing — see **[docs/quotas-and-limits.md](quotas-and-limits.md)**.
- If seeding fails for any reason — a storage problem, or the background queue
  being down so the work cannot even be scheduled — the sign-up itself is
  unaffected: the person still has their account, and the problem is reported to
  the operator.

### The first-run checklist

For 30 days after sign-up, the top of the dashboard shows a three-step card —
*Choose a document*, *Add a signer*, *Send it* — with each step ticked off from
the real data as the work is done, however it was done (dashboard, API or a
share link). It disappears by itself once all three are done, and anybody can
put it away sooner with the **×**. Each person on the account dismisses it for
themselves. While it is showing, the app tour's "Welcome" card stands aside —
two onboarding cards making the same offer on one screen is one too many, and
the tour is still there from the template builder.

### After the first signed document

The first time a free account's very first document is signed, a one-time
banner appears on the dashboard for that account's administrators: *Your first
document is signed*, with a sentence about what the paid plan adds and a button
to the billing page. It is written once, ever — dismissing it puts it away for
the whole account, and it never comes back at a month rollover or after a
change of plan. An account that is suspended, or a person parked read-only, is
not shown it at all: they would not be allowed to dismiss it, and a card that
cannot be put away is worse than no card.

"First ever" is decided from the completion that has just been recorded, not
from a count taken afterwards, so a first document with two signers finishing
together, or two documents finishing in the same second, still arms it exactly
once. A completion that lands on a linked child account arms the parent that
pays.

## 6. What signing up records

All three sign-up doors — email + password, Continue with Google and Continue with Apple — write down
that the person agreed to the **Terms of Service** and the **Privacy Policy**,
which are linked in one sentence under the sign-up form and published at the
public pages `/terms` and `/privacy`. Two rows are written per person (one per
document), each holding the version they were shown, a SHA-256 of the exact
text, the time, the IP address and the browser. They are written in the same
transaction as the account itself, so a sign-up that fails leaves neither.

Accepting a team invitation as a *new* person is the third door and does the
same thing; the invitation page carries the same sentence and the same two
links. Accepting one as somebody who already has an account is a move, not a
sign-up, and records nothing new — their existing agreement moves with them.

The **sign-in page is a sign-up door too**: its *Continue with Google* and *Continue with Apple* buttons
creates an account for an address that has never signed up, so that page
carries the same sentence and the same two links.

Every one of those pages sends back the **version** of each document it was
displaying, and a door refuses — *"Our terms were updated while you were
reading"* — rather than record an agreement to words the person never saw. A
request that sends no versions at all is refused the same way.

See **[docs/legal.md](legal.md)** for the versioning rule and for what a
lawyer still has to settle.
