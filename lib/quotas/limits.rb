# frozen_string_literal: true

module Quotas
  # The constants table for every quota, throttle and abuse policy in the
  # product (docs/quotas-and-limits.md). Internal and operator accounts are
  # exempt from every row. Paid accounts are never auto-blocked by a quota
  # (D42): their rows are warn-flags for the operator, not refusals.
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

    # Paid completions soft-warn email; storage 80% warning (both plans).
    WARNING_FRACTION = 0.8

    # Registration (Phase C reads these).
    SIGNUPS_PER_IP_PER_HOUR = 5
    SIGNUPS_PER_IP_PER_DAY = 20

    # Abuse policy — any customer account (lib/sending_pause.rb).
    COMPLAINTS_TO_PAUSE = 1   # one spam complaint pauses sending
    BOUNCE_WINDOW = 20        # hard bounces among the last 20 sends...
    BOUNCE_MIN_SENDS = 10     # ...once at least 10 have gone out...
    BOUNCE_PAUSE_RATE = 0.20  # ...pause sending at a 20% share
  end
end
