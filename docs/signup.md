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

**Apple Sign-In** is not offered. The `APPLE_*` variables are placeholders
and the button does not exist; adding it is a launch-gate item, not part of
this build.

## 3. The four abuse guards

| Guard | What it does | Numbers |
| --- | --- | --- |
| Cloudflare Turnstile | Every email sign-up carries a one-time token from the widget; the server asks Cloudflare whether it is genuine. A blank token, a Cloudflare outage or a missing secret all **fail closed** — the form re-renders with *Please complete the verification and try again* and nothing is written. There is no environment bypass; the test suite stubs the HTTP call. | one check per submission, 5 s timeout |
| Disposable-address blocklist | Addresses at throwaway-mail domains (the `valid_email2` list, e.g. mailinator.com) are refused with *Please use a permanent email address*. Sign-up only: an admin may still invite such an address to their own account, and internal provisioning is untouched. The domain list is checked, never DNS. | — |
| Per-network limits | Sign-ups from one IP address are counted — sign-ups, not attempts. On the email path an attempt counts only once the Turnstile check and the form's own checks (a valid, permanent, untaken address; a long enough password) have passed, immediately before the account is written; a typo, a taken address or a failed CAPTCHA never spends the budget, so five mistakes from one office never lock the office out. On the Google path only the creation of a new account counts (an existing user signing in with Google is not a sign-up). Past the limit the form answers *Too many sign-ups from this network* with status 429 and the Google path returns to the sign-in page with the same message. Invitations and sign-in are not counted. Redis-backed like the other velocity limits: if Redis is down the limit is off, never the sign-up. | 5 per hour, 20 per day |
| Per-network attempt ceiling | A second, separate count: every sign-up **attempt** from one IP address, however it ends, and every hit on a Google `/auth/...` endpoint. Checked first, before anything outbound happens — the Turnstile check is a call to Cloudflare that waits up to five seconds, and the Google callback makes OmniAuth call Google, so an attempt anyone can replay for free is a web thread they can hold for free. Past the ceiling the form answers *Too many sign-ups from this network* (429) and the Google endpoints answer 429 with an empty body. Set far above honest use: a whole office behind one address never gets near it. Redis-backed and fails open the same way. | 30 sign-up attempts per hour, 60 Google hits per hour |

## 4. The switch

`REGISTRATION_ENABLED=true` opens sign-up. Anything else keeps it closed:

- `/sign_up`, the check-your-email page, the confirmation resend form and
  every `/auth/...` Google endpoint answer **404** (empty body).
- The sign-in page shows no *Create free account* link and no Google
  button; the navbar shows no sign-up button.
- Existing users sign in, reset passwords and get invited exactly as before.

In production the app **refuses to boot** with the switch on and the
Turnstile keys missing (an open door that could never let anyone in). Missing
Google credentials only hide the button and log a warning.

## 5. What signing up records

Both sign-up doors — email + password, and Continue with Google — write down
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

The **sign-in page is a sign-up door too**: its *Continue with Google* button
creates an account for an address that has never signed up, so that page
carries the same sentence and the same two links.

Every one of those pages sends back the **version** of each document it was
displaying, and a door refuses — *"Our terms were updated while you were
reading"* — rather than record an agreement to words the person never saw. A
request that sends no versions at all is refused the same way.

See **[docs/legal.md](legal.md)** for the versioning rule and for what a
lawyer still has to settle.
