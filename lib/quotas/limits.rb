# frozen_string_literal: true

module Quotas
  # The constants table for every quota, throttle and abuse policy in the
  # product (docs/quotas-and-limits.md). Internal and operator accounts are
  # exempt from every row. Paid in-app sending stays warn-only (D42); the
  # API-channel allowance deliberately refuses new automation documents (D79).
  module Limits
    # Free — hard caps, per UTC calendar month.
    FREE_COMPLETIONS_PER_MONTH = 5     # first-signer completions
    FREE_COMPLETIONS_WARNING_AT = 4    # warning email at 4/5
    FREE_SENDS_PER_MONTH = 15          # submissions created, any source
    FREE_IN_FLIGHT = 10                # open submissions at once
    FREE_SEATS = 1
    FREE_STORAGE_BYTES = 1.gigabyte    # blocks account-user uploads only

    # Paid — scale with seats; storage blocks uploads only, never sending.
    PAID_STORAGE_BYTES_PER_SEAT = 10.gigabytes
    PAID_COMPLETIONS_REVIEW_PER_SEAT = 500 # fair-use review flag, never a block
    PAID_SENDS_PER_DAY_PER_SEAT = 200      # velocity warn-flag
    PAID_IN_FLIGHT_PER_SEAT = 50           # warn-flag

    # D79: API/embed/MCP capacity is per billing account, never per seat.
    PAID_API_COMPLETIONS_PER_MONTH = 50
    BUSINESS_API_COMPLETIONS_PER_MONTH = 500
    API_PACK_COMPLETIONS_PER_MONTH = 50

    # Paid completions soft-warn email; storage 80% warning (both plans).
    WARNING_FRACTION = 0.8

    # Registration (Phase C reads these).
    SIGNUPS_PER_IP_PER_HOUR = 5
    SIGNUPS_PER_IP_PER_DAY = 20
    # Attempts, not sign-ups: every POST to the sign-up form and every hit on
    # an OmniAuth endpoint, however it ends. The two rows above count what was
    # created and are spent only on success (a typo must not lock an office
    # out); these count what was asked for and are spent whatever the answer,
    # because each attempt costs the server an outbound HTTPS call — Cloudflare
    # for the form, Google's token endpoint for the OmniAuth path — that holds
    # a web thread for up to five seconds while it waits. Set far above honest
    # use (a whole office behind one address, fumbling the CAPTCHA and starting
    # over, is nowhere near 30 sign-up attempts or 60 Google round-trips in an
    # hour) and far below the sustained rate a thread-exhaustion attempt needs.
    SIGNUP_ATTEMPTS_PER_IP_PER_HOUR = 30
    OAUTH_ATTEMPTS_PER_IP_PER_HOUR = 60

    # Email-2FA verification codes a share link may send in an hour, counted
    # per account. The anonymous send endpoint mails an address nobody has
    # confirmed and creates no Submission row, so neither the monthly sends
    # quota nor anything else on the account grows with it — without a row of
    # its own the only brake is the per-IP one in lib/submitters.rb, and a
    # pool of proxies walks straight around that. The account cannot be
    # swapped the same way, so this is where the brake belongs. An honest link
    # sends one code per visitor who starts the form plus the odd resend; a
    # free account can only ever start 15 documents in a whole month, and even
    # a busy paid link does not admit a signer every thirty-six seconds for an
    # hour on end. Well above honest use, far below the volume that would make
    # a relay run worth mounting.
    SHARED_LINK_CODES_PER_ACCOUNT_PER_HOUR = 100

    # Signing requests sent AGAIN to a signer who already has one — a resend,
    # an address correction, the API's send_email on an update, a signer's
    # delegation (Submitters::ResendGuard). The first request of a document is
    # bounded by the send quota above; these were bounded by nothing, so one
    # document could relay unlimited mail from our sending address. Counted
    # per UTC day; internal and operator accounts are exempt.
    RESENDS_PER_SIGNER_PER_DAY = 3 # any customer plan, whatever the address
    # Free, per billing account — hard. A free account holds at most 10 open
    # documents: resending to every signer of every one of them fits.
    FREE_RESENDS_PER_DAY = 20
    PAID_RESENDS_PER_DAY_PER_SEAT = 100 # warn-flag for the operator, never a block (D42)

    # Abuse policy — any customer account (lib/sending_pause.rb).
    COMPLAINTS_TO_PAUSE = 1   # one spam complaint pauses sending
    BOUNCE_WINDOW = 20        # hard bounces among the last 20 sends...
    BOUNCE_MIN_SENDS = 10     # ...once at least 10 have gone out...
    BOUNCE_PAUSE_RATE = 0.20  # ...pause sending at a 20% share
  end
end
