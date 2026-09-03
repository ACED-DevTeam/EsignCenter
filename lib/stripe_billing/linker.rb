# frozen_string_literal: true

module StripeBilling
  # The ONE path through which an account's row and a Stripe subscription are
  # ever tied together.
  #
  # Everything about one account's subscription happens inside a single row
  # lock, taken BEFORE Stripe is asked anything: the re-fetch, the decision
  # about which subscription the account really holds, the write, and the
  # dunning clock that follows from it. Fetching first and locking second — the
  # shape this replaces — let two workers each fetch a snapshot and then race
  # for the write, so the OLDER snapshot could land last and hand paid access
  # back to a cancelled account.
  #
  # The lock is held across the Stripe calls on purpose: a job or a request
  # holds its database connection for its whole duration anyway, so the lock
  # changes nothing about pool pressure — it only serialises same-account
  # work, which is the point. What it must not do is wait forever, so every
  # Stripe call is on a short leash (StripeBilling.client) and the lock itself
  # gives up after LOCK_TIMEOUT: a job that hits it fails and retries, a web
  # action turns it into "try again in a minute".
  #
  # The webhook processor, the nightly reconciliation and the Checkout doors
  # all come through here, so "which subscription does this account hold?" is
  # answered in exactly one place (SubscriptionPolicy says what is ours and
  # which of several survives):
  #
  #   * the row holds this same id                 → fetch it and apply it;
  #   * the row holds nothing                      → fetch the newcomer; adopt
  #                                                  it if it is ours, else
  #                                                  leave it alone;
  #   * the row holds a DIFFERENT id               → ask Stripe about the
  #     row's OWN subscription, never the cached columns: still live → the
  #     newcomer is a duplicate (cancelled and refunded, or ignored for an
  #     invoice); over → adopt the newcomer if it is ours.
  module Linker
    RESOURCE_MISSING = 'resource_missing'

    # How long a worker waits for another worker's lock on the same account
    # before giving up. Longer than one bounded Stripe round-trip, shorter
    # than anything a person would wait for a page.
    LOCK_TIMEOUT = '10s'

    # Stripe pages a customer's subscriptions; the app reads every page, but
    # never more than this many — a thousand subscriptions on one customer is
    # not a customer, it is a bug somewhere else.
    LIST_PAGE_SIZE = 100
    LIST_PAGE_LIMIT = 10

    # A duplicate is fetched with its latest invoice and that invoice's
    # payments, because cancelling it is only half the job: whatever it
    # already charged has to go back. (What is actually refunded comes from
    # the duplicate's PAID INVOICE LIST, not from this one invoice — a
    # duplicate that ran for two cycles has two of them.)
    DUPLICATE_EXPAND = ['items.data.price', 'latest_invoice.payments'].freeze
    REFUND_REASON = 'duplicate'

    # The paid invoices of a duplicate, read the same way as its
    # subscriptions: every page, never more than this many, and a list we
    # could not finish is refused rather than treated as "nothing more was
    # charged". Each invoice's payments come expanded, because a refund is
    # made against the PaymentIntent that settled it.
    INVOICE_EXPAND = ['data.payments'].freeze
    PAID_INVOICE_STATUS = 'paid'

    # A refund is made against a PaymentIntent, but only its CHARGE knows how
    # much of it has already gone back — an earlier attempt of ours past
    # Stripe's 24-hour idempotency window, or an operator's manual refund.
    PAYMENT_INTENT_EXPAND = ['latest_charge'].freeze

    # How many separate payments the app will return on its own. A duplicate
    # caught by the next webhook has one; a duplicate nobody noticed for a
    # quarter has three. More than that is not a duplicate the app
    # understands, and money leaves automatically at most this fast: the
    # duplicate is still cancelled, but the refund waits for a person.
    # Counted per PaymentIntent, because that is what a refund is made
    # against — two invoices settled by one card charge are one payment.
    DUPLICATE_REFUND_MAX_PAYMENTS = 3

    # The two markers we leave on a subscription we cancelled as a duplicate,
    # and what they mean to a later pass:
    #
    #   * DUPLICATE_CANCEL_MARKER — we cancelled a subscription that was
    #     created AFTER the one that survived, so every cycle it ever
    #     collected was a second charge for service the survivor was already
    #     billing. Its refund may be made automatically.
    #   * DUPLICATE_CANCEL_MANUAL_MARKER — we cancelled a subscription that
    #     was created BEFORE the survivor (it lost on health: the customer's
    #     original subscription went past_due or incomplete and a healthy
    #     newer one took over). Most of what it collected bought real
    #     service; at most part of one cycle was billed twice, and only a
    #     person can judge that. Nothing is ever refunded automatically.
    #
    # Both mean "we ended this one"; only the first means "we owe its money".
    #
    # Each marker is stamped in TWO places and they are not equals. The
    # subscription's METADATA carries the authority — only a secret key can
    # write it — and is the only thing any money decision reads. The
    # human-readable string also goes into `cancellation_details.comment`
    # for whoever opens the dashboard, and is never consulted by code: our
    # own Customer Portal offers customers a free-text cancellation box that
    # writes exactly that field, so trusting it would let a customer ask for
    # a refund of their whole paid history by typing a string.
    DUPLICATE_CANCEL_METADATA_FOR = {
      StripeBilling::DUPLICATE_CANCEL_MARKER => StripeBilling::DUPLICATE_CANCEL_METADATA,
      StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER => StripeBilling::DUPLICATE_CANCEL_MANUAL_METADATA
    }.freeze

    DUPLICATE_CANCEL_MARKER_FOR = DUPLICATE_CANCEL_METADATA_FOR.invert.freeze

    # `cancelled_id` names the subscription the duplicate path actually
    # cancelled — which is NOT always the one the caller passed in: when the
    # incoming subscription wins the survivor policy, the loser is the one
    # the row used to hold. A summary that names the wrong id sends the
    # operator to the wrong subscription in the dashboard. `manual_note` is
    # set only for the older-loser case, and is what the nightly sweep prints
    # under its manual-review heading.
    Outcome = Struct.new(:verdict, :refund, :cancelled_id, :manual_note)

    Refund = Struct.new(:id, :amount, :currency) do
      # "$30.00" — the price is in dollars and so is every refund of it.
      def formatted_amount
        dollars = format('%.2f', amount.to_i / 100.0)

        currency.to_s.casecmp('usd').zero? ? "$#{dollars}" : "#{dollars} #{currency.to_s.upcase}"
      end
    end

    LiveSubscriptions = Struct.new(:ours, :foreign)

    # One PaymentIntent that settled the duplicate's invoices, and the truth
    # about it read off its charge. Stripe lets one card charge settle
    # several invoices, so `owed` is what the duplicate's invoices actually
    # collected through THIS intent — never more than that comes back, even
    # when the charge itself took more (it was also paying for something
    # else).
    #
    # `refundable` is the only thing the app may send: capped at what the
    # charge still has left, because asking Stripe for money that is already
    # back would either error (the charge is spent) or, worse, be read as a
    # second refund. `returned` is what has already come back that counts
    # against this debt.
    Payment = Struct.new(:payment_intent, :owed, :amount, :refunded, :currency) do
      def returned
        [refunded.to_i, owed.to_i].min
      end

      def refundable
        [owed.to_i, amount.to_i - refunded.to_i].min.clamp(0..)
      end
    end

    # What settling one duplicate came to. `refund` is what THIS pass sent
    # back (nil when nothing needed sending); `already_returned` is what the
    # duplicate had collected and that had already come back before this pass
    # looked — the difference between "nothing was ever charged twice" and
    # "an operator has already put it right", which the operator note must
    # not confuse.
    Settlement = Struct.new(:refund, :already_returned)

    # A duplicate that charged the customer and cannot be refunded by the app:
    # the job must fail loudly rather than record a cancellation that quietly
    # kept the money.
    class RefundUnavailable < StandardError; end

    module_function

    # The row always exists before any Stripe object can be linked to it
    # (Checkout creates it), so a row lock is enough to serialise every writer.
    # `SET LOCAL` scopes the wait limit to this transaction alone; a wait past
    # it raises ActiveRecord::LockWaitTimeout.
    def with_account_lock(account_subscription, &)
      account_subscription.transaction do
        AccountSubscription.connection.execute(
          AccountSubscription.sanitize_sql_array(['SET LOCAL lock_timeout = ?', LOCK_TIMEOUT])
        )

        account_subscription.with_lock(&)
      end
    end

    # Returns an Outcome whose verdict is :applied, :adopted,
    # :duplicate_cancelled, :duplicate_ignored or :foreign_ignored.
    #
    # `cancel_duplicates` is false for invoices (an invoice never cancels
    # anything). `allow_adopt` is false for the nightly sweep, which has
    # already repaired the row from Stripe and must never repoint it on the
    # strength of a list.
    def link_and_apply!(account_subscription, subscription_id, event_id: nil, event_at: nil,
                        cancel_duplicates: true, notify: true, allow_adopt: true)
      with_account_lock(account_subscription) do
        existing = account_subscription.stripe_subscription_id

        if existing == subscription_id
          apply_current!(account_subscription, subscription_id, event_at:)
        elsif existing.blank?
          adopt_if_ours!(account_subscription, subscription_id, event_id:, event_at:)
        else
          decide_between(account_subscription, subscription_id,
                         event_id:, event_at:, cancel_duplicates:, notify:, allow_adopt:)
        end
      end
    end

    # Every subscription Stripe still calls live for this customer, split into
    # the ones that are ours (survivor first) and strangers we leave alone.
    def live_subscriptions(customer_id, account_id)
      live = customer_subscriptions(customer_id).select { |subscription| SubscriptionPolicy.live?(subscription) }
      ours, foreign = live.partition { |subscription| SubscriptionPolicy.ours?(subscription, account_id) }

      LiveSubscriptions.new(ours: SubscriptionPolicy.survivor_order(ours), foreign:)
    end

    def live_subscription_ids(customer_id, account_id)
      live_subscriptions(customer_id, account_id).ours.map { |subscription| SubscriptionSync.field(subscription, :id) }
    end

    # Under the caller's account lock: whatever live subscriptions of ours the
    # customer already has get linked — the survivor becomes the account's,
    # every other one goes through the duplicate path. Returns whether any
    # was found (so the caller can refuse to sell another).
    def link_live_subscriptions!(account_subscription, customer_id)
      live = live_subscriptions(customer_id, account_subscription.account_id)

      report_foreign(account_subscription, live.foreign)

      live.ours.each do |subscription|
        link_and_apply!(account_subscription, SubscriptionSync.field(subscription, :id))
      end

      live.ours.any?
    end

    # What the ROW says about the subscription it holds, without asking Stripe.
    # Only ever a first, cheap answer (the billing page's buttons, the
    # Checkout pre-check); every decision that moves money asks Stripe.
    def holds_live_subscription?(account_subscription)
      return false if account_subscription.stripe_subscription_id.blank?
      return true if Plans::PAID_ACCESS_STATES.include?(account_subscription.access_state)

      SubscriptionPolicy.live_status?(account_subscription.stripe_status)
    end

    # --- inside the lock -----------------------------------------------------

    # Every page of the customer's subscriptions, dead ones included: the
    # list is filtered here, never by Stripe's paging, so a page of ten dead
    # subscriptions cannot hide a live one behind `has_more`.
    def customer_subscriptions(customer_id)
      return [] if customer_id.blank?

      found = paginate({ customer: customer_id, status: 'all' }) do |params|
        StripeBilling.client.v1.subscriptions.list(params)
      end

      # A list we could not finish is not a list: deciding "no live
      # subscription" on it could sell a second one.
      if found.nil?
        raise StripeBilling::ListIncomplete,
              "customer #{customer_id} has more than #{LIST_PAGE_SIZE * LIST_PAGE_LIMIT} subscriptions"
      end

      found
    end

    # Every page of a Stripe list, up to the cap, or nil when the cap was
    # reached with Stripe still saying `has_more`. The caller decides what an
    # unfinished list means — refusing to sell a second subscription on one,
    # refusing to call a partial refund a whole one — but nobody may treat it
    # as "that was everything", so it never comes back as a short array.
    def paginate(params)
      found = []
      params = params.merge(limit: LIST_PAGE_SIZE)
      more = true

      LIST_PAGE_LIMIT.times do
        page = yield(params)
        found.concat(Array(page.data))
        more = SubscriptionSync.truthy?(SubscriptionSync.field(page, :has_more)) && page.data.any?

        break unless more

        params = params.merge(starting_after: SubscriptionSync.field(page.data.last, :id))
      end

      more ? nil : found
    end

    # The row holds nothing yet. A newcomer that is not ours is never written
    # onto the row: paid access is not granted for somebody else's purchase.
    def adopt_if_ours!(account_subscription, subscription_id, event_id:, event_at:)
      stripe_subscription = StripeBilling.subscription_for(subscription_id)

      unless SubscriptionPolicy.ours?(stripe_subscription, account_subscription.account_id)
        return foreign_ignored(account_subscription, subscription_id, event_id:)
      end

      account_subscription.update!(stripe_subscription_id: subscription_id)

      apply_object!(account_subscription, stripe_subscription, event_at:)

      Outcome.new(verdict: :adopted)
    end

    # The row holds ANOTHER subscription. Ask Stripe about that one — never
    # the cached columns, which may be stale in either direction — and write
    # what Stripe says while it is in hand. When both are live and ours, the
    # survivor policy decides (not arrival order): the loser goes through
    # the duplicate path whichever one it is.
    def decide_between(account_subscription, subscription_id, event_id:, event_at:, cancel_duplicates:, notify:,
                       allow_adopt:)
      own = StripeBilling.subscription_for(account_subscription.stripe_subscription_id)

      if SubscriptionPolicy.live?(own)
        SubscriptionSync.apply!(account_subscription, own)

        return Outcome.new(verdict: :duplicate_ignored) unless cancel_duplicates

        settle_between_live!(account_subscription, own, subscription_id, event_id:, event_at:, notify:)
      else
        settle_own_refund!(account_subscription, own, event_id:, notify:)

        if allow_adopt
          adopt_if_ours!(account_subscription, subscription_id, event_id:, event_at:)
        else
          Outcome.new(verdict: :duplicate_ignored)
        end
      end
    end

    # The row's own subscription is over — and when our AUTOMATIC marker is
    # on it, an earlier attempt cancelled it as a newer duplicate and then
    # failed (or was rolled back) before the money went back. That debt is
    # settled here, BEFORE the row moves on to the survivor: once the row
    # names another subscription, nothing ever looks at this one again and
    # the refund is lost silently. This is not adoption from a list — it is
    # our own, marked subscription re-fetched under the lock — so the nightly
    # sweep settles it too. Refunds carry Stripe idempotency keys, so a
    # second pass over an already-refunded duplicate costs nothing.
    #
    # The marker alone says the whole debt: we only write it on a duplicate
    # created after the survivor, so every cycle it collected was a second
    # charge. A subscription carrying the MANUAL marker is settled as far as
    # this path is concerned — no refund, no alert; a person owns it.
    def settle_own_refund!(account_subscription, own, event_id:, notify:)
      return nil unless auto_refundable?(own)

      settlement = refund_duplicate_charge!(own)

      return nil if settlement.refund.nil?

      report_owed_refund(account_subscription, SubscriptionSync.field(own, :id), settlement:, event_id:, notify:)

      settlement.refund
    rescue Stripe::StripeError, RefundUnavailable => e
      report_owed_refund(account_subscription, SubscriptionSync.field(own, :id),
                         refund_error: e, event_id:, notify: true)

      raise
    end

    # The nightly sweep's backstop for the same debt. The row still names a
    # subscription WE cancelled as a duplicate and never refunded (an earlier
    # attempt died between the cancellation and the money); no webhook will
    # ever arrive about a dead subscription, so without this the refund is
    # kept silently. Its own subscription is re-fetched under the row lock —
    # never adopted off a list — and the marker on it, read under that same
    # lock, is what says whether anything is owed. Returns the Refund made,
    # or nil when nothing was.
    def settle_owed_refund!(account_subscription, event_id: nil, notify: false)
      own_id = account_subscription.stripe_subscription_id

      return nil if own_id.blank?

      with_account_lock(account_subscription) do
        own = StripeBilling.subscription_for(own_id)

        next nil if SubscriptionPolicy.live?(own)

        settle_own_refund!(account_subscription, own, event_id:, notify:)
      end
    end

    # The row's own subscription is live; the newcomer is fetched and, if it
    # is live too and wins on the survivor policy (our price, earliest
    # created), the row moves to it and the FORMER subscription is the
    # duplicate. Otherwise the newcomer is.
    def settle_between_live!(account_subscription, own, subscription_id, event_id:, event_at:, notify:)
      incoming = StripeBilling.subscription_for(subscription_id, expand: DUPLICATE_EXPAND)

      refuse_foreign!(account_subscription, incoming)

      incoming_wins = SubscriptionPolicy.live?(incoming) &&
                      SubscriptionPolicy.survivor_order([own, incoming]).first.equal?(incoming)

      unless incoming_wins
        return cancel_duplicate!(account_subscription, subscription_id, event_id:, notify:, duplicate: incoming,
                                                                        survivor: own)
      end

      former_id = account_subscription.stripe_subscription_id

      account_subscription.update!(stripe_subscription_id: subscription_id)
      apply_object!(account_subscription, incoming, event_at:)

      cancel_duplicate!(account_subscription, former_id, event_id:, notify:, survivor: incoming)
    end

    # Never trust the payload that got us here: ask Stripe what is true now
    # and write that. Idempotent, so a replayed or out-of-order event simply
    # writes the same row again.
    def apply_current!(account_subscription, subscription_id, event_at:)
      apply_object!(account_subscription, StripeBilling.subscription_for(subscription_id), event_at:)

      Outcome.new(verdict: :applied)
    end

    def apply_object!(account_subscription, stripe_subscription, event_at:)
      SubscriptionSync.apply!(account_subscription, stripe_subscription)

      stamp_event!(account_subscription, event_at)
    end

    # The newest Stripe event this row has seen; it never moves backwards.
    def stamp_event!(account_subscription, event_at)
      newest = [account_subscription.last_stripe_event_at, event_at].compact.max

      account_subscription.update!(last_stripe_event_at: newest) if newest
    end

    def foreign_ignored(account_subscription, subscription_id, event_id:)
      ErrorReport.warning("Stripe subscription #{subscription_id} on account " \
                          "#{account_subscription.account_id}'s customer is not ours; left alone",
                          account_id: account_subscription.account_id, stripe_event_id: event_id)

      Outcome.new(verdict: :foreign_ignored)
    end

    def report_foreign(account_subscription, foreign)
      foreign.each do |subscription|
        ErrorReport.warning("foreign subscription #{SubscriptionSync.field(subscription, :id)} on customer " \
                            "#{account_subscription.stripe_customer_id} left alone",
                            account_id: account_subscription.account_id)
      end
    end

    # --- the duplicate path --------------------------------------------------

    # A second live subscription of ours on one customer is a double charge
    # however we hear about it. The newcomer is fetched (a stranger's
    # subscription is refused outright, never cancelled), cancelled at
    # Stripe, and whatever it already charged is refunded; the operator is
    # told either way. `notify` is false for the nightly sweep, which sends
    # ONE summary email however many duplicates it found — except when a
    # refund fails, which always reaches a person.
    #
    # Only what WE cancel is ever refunded. A candidate that is already dead
    # when fetched is somebody's history — a stale event for an old,
    # legitimately ended subscription, a bookmarked return URL — unless it
    # carries one of our own cancellation markers, which means a previous
    # attempt cancelled it (and, for the automatic marker, that its refund is
    # still owed).
    #
    # WHICH marker goes on it is the whole money decision, and it turns on
    # one comparison: was the loser created after the survivor, or before it?
    #
    #   * created AFTER  → every cycle it ever collected duplicated one the
    #     survivor was already billing. Automatic marker, automatic refund.
    #   * created BEFORE → it lost on health, not on age: the customer's
    #     original subscription stopped collecting and a healthy newer one
    #     won. Its history bought real service and is not ours to unwind;
    #     at most part of one cycle overlapped. Manual marker, no automatic
    #     refund, and a person is told what to look at.
    #   * UNPROVEN (no survivor to compare, or a creation time we could not
    #     read on either side) → the manual marker, never the automatic one.
    #     An unproven comparison must not move money.
    def cancel_duplicate!(account_subscription, duplicate_id, event_id: nil, notify: true, duplicate: nil,
                          survivor: nil)
      duplicate ||= StripeBilling.subscription_for(duplicate_id, expand: DUPLICATE_EXPAND)

      refuse_foreign!(account_subscription, duplicate)

      cancelled, marker = end_duplicate!(duplicate, survivor)

      return stale_ignored(account_subscription, duplicate_id, event_id:) if cancelled.nil?

      if marker == StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER
        return manual_duplicate(account_subscription, duplicate_id, survivor:, event_id:, notify:)
      end

      settlement = refund_duplicate_charge!(cancelled)

      report_duplicate(account_subscription, duplicate_id, settlement:, event_id:, notify:)

      Outcome.new(verdict: :duplicate_cancelled, refund: settlement.refund, cancelled_id: duplicate_id)
    rescue Stripe::StripeError, RefundUnavailable => e
      raise unless cancelled

      report_duplicate(account_subscription, duplicate_id, refund_error: e, event_id:, notify: true)

      raise
    end

    # Ends the duplicate at Stripe under the marker its age earns, and
    # returns both. A duplicate that is ALREADY dead is not cancelled again:
    # whatever marker a previous attempt left on it is the one that governs,
    # so a retry cannot promote a manual case into an automatic refund.
    def end_duplicate!(duplicate, survivor)
      if SubscriptionPolicy.dead?(duplicate)
        already = cancelled_by_us(duplicate)

        return [already, stored_marker(already)]
      end

      marker = duplicate_marker(duplicate, survivor)

      [cancel_at_stripe!(duplicate, marker), marker]
    end

    # The automatic marker is the one that moves money, so it has to be
    # EARNED: only a proven "this loser was created after the survivor"
    # unlocks it. Without a survivor to compare against, or with either
    # creation time missing or unusable, nothing is proven and the manual
    # marker stands — the duplicate is still cancelled, a person is told,
    # and the only cost of being wrong is their time.
    def duplicate_marker(duplicate, survivor)
      return StripeBilling::DUPLICATE_CANCEL_MARKER if newer_loser?(duplicate, survivor)

      StripeBilling::DUPLICATE_CANCEL_MANUAL_MARKER
    end

    # Strictly the newer one, on two timestamps we could actually read. Two
    # subscriptions created in the same second are a double Checkout and the
    # loser's cycles are genuinely second charges, so equality counts as
    # newer.
    def newer_loser?(duplicate, survivor)
      loser_created = SubscriptionSync.field(duplicate, :created).to_i
      survivor_created = SubscriptionSync.field(survivor, :created).to_i

      loser_created.positive? && survivor_created.positive? && loser_created >= survivor_created
    end

    # The older loser: cancelled, never refunded by the app, and handed to a
    # person with everything they need to judge the partial cycle — which
    # subscription we ended, which one took over and when, and the last
    # invoice the ended one actually collected.
    def manual_duplicate(account_subscription, duplicate_id, survivor:, event_id:, notify:)
      note = manual_refund_note(duplicate_id, survivor)

      report_manual_duplicate(account_subscription, duplicate_id, note:, event_id:, notify:)

      Outcome.new(verdict: :duplicate_cancelled, cancelled_id: duplicate_id, manual_note: note)
    end

    def refuse_foreign!(account_subscription, duplicate)
      return if SubscriptionPolicy.ours?(duplicate, account_subscription.account_id)

      raise ArgumentError, "refusing to cancel #{SubscriptionSync.field(duplicate, :id)}: it is not an " \
                           "EsignCenter subscription (account #{account_subscription.account_id})"
    end

    # Returns the cancelled subscription as Stripe now sees it, stamped with
    # our marker; or nil when it was already gone by someone else's hand
    # (nothing of ours to refund). Only "it is already gone" is swallowed:
    # any other invalid request means the duplicate may still be billing
    # somebody, and the job must retry rather than record a cancellation
    # that never happened.
    def cancel_at_stripe!(duplicate, marker)
      duplicate_id = SubscriptionSync.field(duplicate, :id)

      mark_duplicate_at_stripe!(duplicate_id, marker)

      StripeBilling.client.v1.subscriptions.cancel(
        duplicate_id,
        { expand: DUPLICATE_EXPAND, cancellation_details: { comment: marker } }
      )
    rescue Stripe::InvalidRequestError => e
      raise unless already_gone?(e, duplicate_id)

      Rails.logger.info("Duplicate subscription #{duplicate_id} was already gone (#{e.message})")

      nil
    end

    # Stamps the marker into the subscription's metadata BEFORE the cancel,
    # because metadata is the app's whole memory of "we ended this and this
    # is what we owe on it" and only a secret key can write it. It has to
    # land first: a cancel without the marker leaves a dead subscription we
    # cannot tell from somebody else's history, so if this write fails
    # nothing is cancelled and the event fails loudly (the only exception is
    # the shared "it is already gone" rescue in the caller, which is not a
    # failure at all — there is nothing left to cancel).
    #
    # Keyed idempotently on the subscription so a retry inside Stripe's
    # window re-writes the same marker rather than a second one, and the
    # answer is discarded: the cancel that follows returns the subscription
    # this path actually reads.
    def mark_duplicate_at_stripe!(duplicate_id, marker)
      StripeBilling.client.v1.subscriptions.update(
        duplicate_id,
        { metadata: { StripeBilling::DUPLICATE_CANCEL_METADATA_KEY =>
                        DUPLICATE_CANCEL_METADATA_FOR.fetch(marker),
                      StripeBilling::DUPLICATE_CANCEL_METADATA_AT_KEY => Time.now.to_i.to_s } },
        idempotency_key: "mark-duplicate-#{duplicate_id}"
      )

      nil
    end

    # Stripe explicitly calls it finished (or never heard of it). A missing
    # or blank status is not "gone".
    def already_gone?(error, duplicate_id)
      return true if error.code.to_s == RESOURCE_MISSING

      SubscriptionPolicy.dead?(StripeBilling.subscription_for(duplicate_id, expand: DUPLICATE_EXPAND))
    rescue Stripe::StripeError
      false
    end

    # Did WE end this one? Either marker says yes — which is what "not
    # somebody else's history" means at the stale-event door. Read from
    # metadata only: the dashboard comment beside it is for people.
    def cancelled_by_us(dead_subscription)
      DUPLICATE_CANCEL_MARKER_FOR.key?(marker_metadata(dead_subscription)) ? dead_subscription : nil
    end

    # Is it ours to refund automatically? Only the plain marker says so; the
    # manual one means a person owns the money question.
    def auto_refundable?(dead_subscription)
      marker_metadata(dead_subscription) == StripeBilling::DUPLICATE_CANCEL_METADATA
    end

    # Which marker a previous pass left on an already-dead duplicate, as the
    # human-readable string the rest of this class compares against; nil when
    # we did not end it.
    def stored_marker(dead_subscription)
      DUPLICATE_CANCEL_MARKER_FOR[marker_metadata(dead_subscription)]
    end

    # The ONLY field any of the above may read. `cancellation_details.comment`
    # is deliberately not consulted anywhere: the Customer Portal lets the
    # customer write it.
    def marker_metadata(subscription)
      return nil if subscription.nil?

      SubscriptionSync.field(SubscriptionSync.field(subscription, :metadata),
                             StripeBilling::DUPLICATE_CANCEL_METADATA_KEY)&.to_s
    end

    def stale_ignored(account_subscription, duplicate_id, event_id:)
      Rails.logger.info("Subscription #{duplicate_id} on account #{account_subscription.account_id} was already " \
                        'over and not cancelled by us; nothing cancelled, nothing refunded')
      ErrorReport.info("stale subscription #{duplicate_id} ignored (already over, not ours to refund)",
                       account_id: account_subscription.account_id, stripe_event_id: event_id)

      Outcome.new(verdict: :duplicate_ignored)
    end

    # Money back for what the DUPLICATION cost. This runs only for a
    # duplicate carrying the AUTOMATIC marker, i.e. one created after the
    # survivor — so every paid cycle of its life is a second charge and the
    # whole paid-invoice list is owed. (The older-loser case never reaches
    # here; it is a person's decision.)
    #
    # Two rules keep the amount honest:
    #
    #   * one refund per PaymentIntent, never per invoice: Stripe lets one
    #     card charge settle several invoices, and two refunds against one
    #     charge is either a double return or a permanently failing event;
    #   * each refund is capped both by what those invoices collected through
    #     that intent and by what the charge still has left, and the
    #     shortfall check counts what has already come back as returned, so
    #     a half-finished attempt finishes rather than failing forever.
    #
    # Above the cap nothing is sent at all (refuse_uncapped_refund!). The
    # total returned is then checked against what the invoices say was
    # collected: a refund that came up short must fail loudly, or a partial
    # return would be reported to the operator and to the customer as if the
    # whole charge had gone back. A trial duplicate has no paid invoice at
    # all and nothing to refund; one already refunded by hand has nothing
    # left to send, and neither may tell the customer money was sent back
    # now.
    def refund_duplicate_charge!(cancelled)
      invoices = paid_invoices(SubscriptionSync.field(cancelled, :id))
      collected = invoices.sum { |invoice| SubscriptionSync.field(invoice, :amount_paid).to_i }

      return Settlement.new(refund: nil, already_returned: 0) unless collected.positive?

      payments = grouped_payments(invoices)

      refuse_uncapped_refund!(cancelled, payments)

      refunds = payments.filter_map { |payment| refund_payment!(payment) }
      returned = payments.sum(&:returned) + refunds.sum(&:amount)

      if returned < collected
        raise RefundUnavailable, "duplicate #{SubscriptionSync.field(cancelled, :id)} collected #{collected} " \
                                 "but only #{returned} could be returned"
      end

      return Settlement.new(refund: nil, already_returned: collected) if refunds.empty?

      Settlement.new(refund: Refund.new(id: refunds.map(&:id).join(', '), amount: refunds.sum(&:amount),
                                        currency: refunds.first.currency),
                     already_returned: 0)
    end

    # An automatic refund puts a double charge right; it does not empty an
    # account's billing history on its own. Above the cap the duplicate is
    # still cancelled at Stripe — the double billing stops either way — but
    # the money waits for a person, and the loud path (failed event, "REFUND
    # FAILED" alert) is exactly how they hear about it. Once that person has
    # refunded by hand there is no remainder left on any payment, so the next
    # pass converges quietly instead of refusing again.
    def refuse_uncapped_refund!(cancelled, payments)
      owed = payments.select { |payment| payment.refundable.positive? }

      return if owed.size <= DUPLICATE_REFUND_MAX_PAYMENTS

      raise RefundUnavailable,
            "duplicate #{SubscriptionSync.field(cancelled, :id)} needs manual review: #{owed.size} payments, " \
            "#{money(owed.sum(&:refundable))} still to return; more than #{DUPLICATE_REFUND_MAX_PAYMENTS} " \
            'payments is past what the app returns unattended'
    end

    # Every invoice of this subscription Stripe calls paid, every page of
    # them. A list we could not finish is not a list: refunding on it would
    # return part of the money and call it all of it.
    def paid_invoices(subscription_id)
      found = paginate({ subscription: subscription_id, status: PAID_INVOICE_STATUS,
                         expand: INVOICE_EXPAND }) do |params|
        StripeBilling.client.v1.invoices.list(params)
      end

      if found.nil?
        raise RefundUnavailable,
              "subscription #{subscription_id} has more than #{LIST_PAGE_SIZE * LIST_PAGE_LIMIT} paid invoices"
      end

      found
    end

    # The duplicate's paid invoices, collapsed onto the PaymentIntents that
    # actually settled them: what each intent collected for this
    # subscription is added up across every invoice it paid, so one card
    # charge behind two invoices is ONE debt and gets ONE refund. An invoice
    # that collected money but names no payment is refused rather than
    # silently skipped.
    def grouped_payments(invoices)
      owed = Hash.new(0)
      currencies = {}

      invoices.each do |invoice|
        amount_paid = SubscriptionSync.field(invoice, :amount_paid).to_i

        next unless amount_paid.positive?

        intents = paid_payment_intents(invoice)

        if intents.empty?
          raise RefundUnavailable, "invoice #{SubscriptionSync.field(invoice, :id)} collected #{amount_paid} " \
                                   'but names no payment intent to refund'
        end

        intents.each do |intent|
          owed[intent] += amount_paid
          currencies[intent] ||= SubscriptionSync.field(invoice, :currency)
        end
      end

      owed.map { |intent, cents| payment_state(intent, cents, currencies[intent]) }
    end

    # The charge behind a PaymentIntent is the only record of what it really
    # took and what has already been returned — by an earlier attempt of ours
    # whose Stripe idempotency key has since expired, or by an operator
    # refunding in the dashboard. Reading it is what makes a half-finished
    # refund finishable, and what keeps the app from asking for more than the
    # charge still holds.
    def payment_state(payment_intent, owed, currency)
      intent = StripeBilling.client.v1.payment_intents.retrieve(payment_intent, { expand: PAYMENT_INTENT_EXPAND })
      charge = SubscriptionSync.field(intent, :latest_charge)

      raise RefundUnavailable, "payment #{payment_intent} names no charge to refund" if charge.blank? ||
                                                                                        charge.is_a?(String)

      captured = SubscriptionSync.field(charge, :amount_captured).to_i
      captured = SubscriptionSync.field(charge, :amount).to_i unless captured.positive?

      Payment.new(payment_intent:, owed:, amount: captured,
                  refunded: SubscriptionSync.field(charge, :amount_refunded).to_i,
                  currency: SubscriptionSync.field(charge, :currency).presence || currency)
    end

    # One refund per PaymentIntent, keyed on the intent so a retry inside
    # Stripe's idempotency window lands on the same refund — and so two
    # invoices behind one charge cannot be sent back twice under two
    # different keys. The `amount` is explicit and is only what is still
    # refundable: past that window the key is dead, and asking again for the
    # whole charge would either error (it is spent) or return money a second
    # time.
    def refund_payment!(payment)
      return nil unless payment.refundable.positive?

      refund = StripeBilling.client.v1.refunds.create(
        { payment_intent: payment.payment_intent, amount: payment.refundable, reason: REFUND_REASON },
        idempotency_key: "refund-duplicate-#{payment.payment_intent}"
      )

      Refund.new(id: refund.id, amount: refund.amount.to_i, currency: payment.currency)
    end

    # In this API version an invoice's payments live under `payments` (a
    # list, expanded on request); each names the PaymentIntent that settled
    # it — a bare id when unexpanded, an object when expanded. All of them,
    # because one invoice can be settled by several payments.
    def paid_payment_intents(invoice)
      payments = Array(SubscriptionSync.field(SubscriptionSync.field(invoice, :payments), :data))

      intents = payments.filter_map do |payment|
        next unless SubscriptionSync.field(payment, :status).to_s == 'paid'
        next unless SubscriptionSync.field(SubscriptionSync.field(payment, :payment), :type).to_s == 'payment_intent'

        intent = SubscriptionSync.field(SubscriptionSync.field(payment, :payment), :payment_intent)

        intent.is_a?(String) ? intent : SubscriptionSync.field(intent, :id)
      end

      intents.compact_blank.uniq
    end

    def report_duplicate(account_subscription, duplicate_id, event_id:, notify:, settlement: nil, refund_error: nil)
      message = duplicate_message(account_subscription, duplicate_id)

      ErrorReport.warning(message, account_id: account_subscription.account_id, stripe_event_id: event_id,
                                   refund_id: settlement&.refund&.id, refund_error: refund_error&.message)

      return unless notify

      OperatorAlert.deliver(
        subject: "Duplicate Stripe subscription cancelled for account #{account_subscription.account_id}",
        body: "#{message}.\n\n#{duplicate_money_note(settlement, refund_error)}"
      )
    end

    # The older loser. Nothing left our account, so there is no refund to
    # report — only a decision for a person, with the two subscriptions and
    # the last money the cancelled one took.
    def report_manual_duplicate(account_subscription, duplicate_id, note:, event_id:, notify:)
      message = duplicate_message(account_subscription, duplicate_id)

      ErrorReport.warning(message, account_id: account_subscription.account_id, stripe_event_id: event_id,
                                   manual_refund_review: true)

      return unless notify

      OperatorAlert.deliver(
        subject: "Duplicate Stripe subscription cancelled for account #{account_subscription.account_id}",
        body: "#{message}.\n\n#{note}"
      )
    end

    def duplicate_message(account_subscription, duplicate_id)
      "Cancelled duplicate Stripe subscription #{duplicate_id} for account " \
        "#{account_subscription.account_id}; it already has #{account_subscription.stripe_subscription_id}"
    end

    # Everything a person needs to settle the partial cycle by hand. The
    # invoice read is best-effort: it is only here to save the operator a
    # search, and failing to read it must not turn a completed cancellation
    # into a failed event.
    def manual_refund_note(duplicate_id, survivor)
      survivor_id = SubscriptionSync.field(survivor, :id).presence || 'unknown'

      ['This one was created BEFORE the subscription that survived, so most of what it collected paid for ' \
       'service the customer had. Nothing was refunded automatically — manual refund review, by hand in ' \
       'the Stripe dashboard, of at most the part-cycle the two overlapped:',
       "  cancelled:               #{duplicate_id}",
       "  survived:                #{survivor_id} (created #{stripe_time(survivor)})",
       "  its latest paid invoice: #{latest_paid_invoice(duplicate_id)}"].join("\n")
    end

    def latest_paid_invoice(duplicate_id)
      latest = paid_invoices(duplicate_id).max_by { |invoice| SubscriptionSync.field(invoice, :created).to_i }

      return 'none — it never collected anything' if latest.nil?

      "#{SubscriptionSync.field(latest, :id)} " \
        "#{money(SubscriptionSync.field(latest, :amount_paid).to_i)} (created #{stripe_time(latest)})"
    rescue Stripe::StripeError, RefundUnavailable => e
      "could not be read (#{e.class}) — list the subscription's invoices in the dashboard"
    end

    def stripe_time(object)
      seconds = SubscriptionSync.field(object, :created).to_i

      seconds.positive? ? Time.zone.at(seconds).utc.iso8601 : 'unknown'
    end

    def money(cents)
      format('$%.2f', cents.to_i / 100.0)
    end

    # The refund an earlier attempt owed and this one made (or could not
    # make). Its own sentence, because the duplicate was cancelled long ago
    # and "cancelled a duplicate" would be news to nobody.
    def report_owed_refund(account_subscription, subscription_id, event_id:, notify:, settlement: nil,
                           refund_error: nil)
      message = "Settled the refund owed on duplicate Stripe subscription #{subscription_id} for account " \
                "#{account_subscription.account_id}, which an earlier attempt cancelled but did not refund"

      ErrorReport.warning(message, account_id: account_subscription.account_id, stripe_event_id: event_id,
                                   refund_id: settlement&.refund&.id, refund_error: refund_error&.message)

      return unless notify

      OperatorAlert.deliver(
        subject: "Duplicate Stripe subscription refunded for account #{account_subscription.account_id}",
        body: "#{message}.\n\n#{duplicate_money_note(settlement, refund_error)}"
      )
    end

    # "Nothing was charged twice" is only true when the duplicate collected
    # nothing at all. A duplicate that DID collect and whose money an
    # operator has since put back by hand has to be told apart from it, or
    # the alert flatly contradicts the customer's bank statement.
    def duplicate_money_note(settlement, refund_error)
      if refund_error
        "REFUND FAILED — refund manually in the Stripe dashboard (#{refund_error.class}: " \
          "#{refund_error.message}). The duplicate is cancelled but its charge has NOT been returned."
      elsif settlement&.refund
        "Its charge of #{settlement.refund.formatted_amount} was refunded (#{settlement.refund.id})."
      elsif settlement && settlement.already_returned.to_i.positive?
        "Its charges of #{money(settlement.already_returned)} had already been returned; nothing more was sent."
      else
        'Nothing was charged twice, but check the customer in Stripe to be sure only one subscription is live.'
      end
    end
  end
end
