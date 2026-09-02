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
- **Existing user, not yet confirmed** → confirmed and signed in. No second
  account is ever created for an address that already has a user.
- **Existing confirmed user** → signed in.
- **User with two-factor authentication** → sent back to the password form
  with a message: the one-time code is entered there, Google never bypasses
  it.
- **Google says the address is not verified**, or the address is on the
  disposable list, or the exchange with Google fails → back to the sign-in
  page with a plain-English message; nothing is created.

The Google path skips Turnstile (Google already gated the request) but keeps
the per-network limit and the disposable-address blocklist.

Sign-in with Google requires a Google OAuth app. Until that app is published
in Google's console it runs in **Testing** mode: only the test users listed
there can use the button (launch-gate item 4b). Everyone else still has the
email path.

**Apple Sign-In** is not offered. The `APPLE_*` variables are placeholders
and the button does not exist; adding it is a launch-gate item, not part of
this build.

## 3. The three abuse guards

| Guard | What it does | Numbers |
| --- | --- | --- |
| Cloudflare Turnstile | Every email sign-up carries a one-time token from the widget; the server asks Cloudflare whether it is genuine. A blank token, a Cloudflare outage or a missing secret all **fail closed** — the form re-renders with *Please complete the verification and try again* and nothing is written. There is no environment bypass; the test suite stubs the HTTP call. | one check per submission, 5 s timeout |
| Disposable-address blocklist | Addresses at throwaway-mail domains (the `valid_email2` list, e.g. mailinator.com) are refused with *Please use a permanent email address*. Sign-up only: an admin may still invite such an address to their own account, and internal provisioning is untouched. The domain list is checked, never DNS. | — |
| Per-network limits | Sign-ups from one IP address are counted — sign-ups, not attempts. On the email path an attempt counts only once the Turnstile check and the form's own checks (a valid, permanent, untaken address; a long enough password) have passed, immediately before the account is written; a typo, a taken address or a failed CAPTCHA never spends the budget, so five mistakes from one office never lock the office out. On the Google path only the creation of a new account counts (an existing user signing in with Google is not a sign-up). Past the limit the form answers *Too many sign-ups from this network* with status 429 and the Google path returns to the sign-in page with the same message. Invitations and sign-in are not counted. Redis-backed like the other velocity limits: if Redis is down the limit is off, never the sign-up. | 5 per hour, 20 per day |

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
