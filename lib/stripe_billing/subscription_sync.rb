# frozen_string_literal: true

module StripeBilling
  # The ONE place a Stripe subscription becomes an AccountSubscription row.
  # Stripe owns the facts (status, quantity, period, trial); the app owns the
  # verdict (`access_state`, which Plans reads to decide paid or free). Every
  # webhook, the Checkout return and the nightly reconciliation all land here,
  # so there is exactly one mapping to reason about — and it is idempotent:
  # applying the same Stripe object twice writes the same row.
  #
  # A downgrade never purges (D43): when Stripe says `canceled` the row keeps
  # every id it had, so the history stays readable and a later Checkout simply
  # brings a new subscription id.
  module SubscriptionSync
    # Stripe status → the app's access state, before the cancel-at-period-end
    # flag is considered. A status we do not know is treated as `cancelled`:
    # paid access is never granted on a word we cannot explain.
    STATE_BY_STRIPE_STATUS = {
      'trialing' => 'trialing',
      'active' => 'active',
      'past_due' => 'past_due',
      'unpaid' => 'suspended',
      'paused' => 'suspended',
      'incomplete' => 'cancelled',
      'incomplete_expired' => 'cancelled',
      'canceled' => 'cancelled'
    }.freeze

    # Only a subscription that is still running can be "cancelling": a
    # past_due or unpaid one carries the flag too, and its state is the
    # payment problem, not the pending cancellation.
    CANCELING_FROM = %w[trialing active].freeze

    # The columns reconciliation compares to decide a row has drifted from
    # Stripe. Everything apply! would write except `synced_at`, which moves on
    # every run and would report drift on every single row.
    DRIFT_ATTRIBUTES = %i[access_state status stripe_status quantity stripe_item_id stripe_price_id
                          stripe_product_id stripe_subscription_id stripe_customer_id current_period_start
                          current_period_end ended_at trial_end trial_used_at past_due_since
                          cancel_at_period_end].freeze

    module_function

    # Pure: what access state this Stripe subscription means. Takes a
    # Stripe::Subscription or any hash shaped like one (the state-table spec
    # feeds it modified copies of real captures).
    def access_state_for(stripe_subscription)
      status = field(stripe_subscription, :status).to_s

      return 'canceling' if truthy?(field(stripe_subscription, :cancel_at_period_end)) &&
                            CANCELING_FROM.include?(status)

      STATE_BY_STRIPE_STATUS.fetch(status, 'cancelled')
    end

    # How apply_vanished! marks its object, so the missing-price warning in
    # apply! stays silent for it: a subscription Stripe no longer has is not a
    # price migration nobody told us about.
    VANISHED_KEY = 'esigncenter_vanished'

    def vanished?(stripe_subscription)
      truthy?(field(stripe_subscription, VANISHED_KEY))
    end

    # A subscription Stripe no longer has (checkpoint 8, C5).
    #
    # `subscriptions.retrieve` answers 404 for a subscription that has been
    # deleted outright at Stripe rather than cancelled — and the row that
    # named it kept whatever access state it was last given, forever, because
    # every sweep filed the 404 as one more transient error. There is nothing
    # to fetch and nothing to compare, but there IS a fact: the subscription
    # is over. So the row takes the ordinary cancelled transition through the
    # ordinary apply path — the state table's `cancelled` row, which is free
    # access, a D43 prospective free month starting now, and no purge — from
    # a subscription object that says exactly the one thing we know.
    #
    # Not hand-written Stripe data: `canceled` is the status Stripe itself
    # uses for a subscription that is over, and every other column the apply
    # path touches falls back to what the row already holds.
    def apply_vanished!(account_subscription)
      apply!(account_subscription,
             { 'id' => account_subscription.stripe_subscription_id,
               'object' => 'subscription',
               'status' => 'canceled',
               'customer' => account_subscription.stripe_customer_id,
               VANISHED_KEY => true })
    end

    def apply!(account_subscription, stripe_subscription)
      if price_item(stripe_subscription).nil? && !vanished?(stripe_subscription)
        report_missing_price(account_subscription, stripe_subscription)
      end

      live_on_a_dead_account = barred?(account_subscription) && paid_state?(stripe_subscription)

      report_barrier(account_subscription, stripe_subscription) if live_on_a_dead_account

      # Read BEFORE the new state is assigned: a paid → free transition is the
      # only moment a free month can start part-way through a calendar month.
      was_paid = paid_row?(account_subscription)

      account_subscription.assign_attributes(attributes_for(account_subscription, stripe_subscription))

      ApplicationRecord.transaction do
        account_subscription.save!

        # D43, prospective counters: the free month starts where the paid one
        # stopped, so the send counter's value at this instant is written down
        # and every free cap from here on is measured against what is sent
        # AFTER it. The counter itself is never touched — deleting a document
        # still never gives a send back. Same transaction as the row that
        # caused it, so the two can never disagree.
        Quotas.record_downgrade!(account_subscription.account) if was_paid && !paid_row?(account_subscription) &&
                                                                  account_subscription.account
      end

      # Everything that happens TO the account because of what Stripe just
      # said — dunning mail, suspension at the end of the grace period,
      # lifting one when the card goes through — hangs off this one call, so
      # the webhook, the Checkout return and the nightly sweep all react
      # identically (BillingLifecycle). It never raises.
      BillingLifecycle.after_apply!(account_subscription)

      # Only once the row above is written, because the cancel has to name the
      # subscription this apply just adopted.
      stop_charging_moved_away!(account_subscription) if live_on_a_dead_account &&
                                                         moved_away?(account_subscription.account)

      account_subscription
    end

    # Is this row's account past the point of no return?
    #
    # Two ways to be, and they are one question — "is there an account left for
    # paid access to mean anything to?" — so they share one barrier rather than
    # each growing their own:
    #
    #   * a purge has CLAIMED it, or it is already a tombstone, so it is being
    #     emptied right now (review batch 2, R2);
    #   * its one member took the "join this team" offer and left, and it was
    #     archived behind them (review 7, D50 D3). That account has no members
    #     at all any more: nobody can sign in to it, reach its billing page,
    #     open its Customer Portal or cancel anything. A subscription attached
    #     to it would charge a card with no door left anywhere to stop it.
    def barred?(account_subscription)
      account = account_subscription.account

      return false if account.nil?

      account.purge_claimed? || moved_away?(account)
    end

    # Archived BY A MOVE, and nothing else.
    #
    # `archived_at` on its own is far too broad a thing to hang a money
    # decision on: the purge stamps it on the tombstone it leaves behind and on
    # every testing child it destroys, and it is what every ordinary "this
    # account is gone" door in the app already reads. What is specific to a
    # move is the AccountMove row the move writes — one line per join, out of
    # this account, written once and never touched again — so the two together
    # name exactly the case this barrier is for and nothing else. A
    # purge-claimed account is still barred through its own predicate, so
    # keeping this one narrow costs nothing.
    def moved_away?(account)
      account.present? && account.archived_at.present? && AccountMove.exists?(from_account_id: account.id)
    end

    # Which barrier this is, and therefore what can be done about it. Both tell
    # a person; only the move can also be closed on the money side, because
    # only there is the app sure the account is finished rather than mid-flight.
    def report_barrier(account_subscription, stripe_subscription)
      return report_moved_away_barrier(account_subscription, stripe_subscription) if
        moved_away?(account_subscription.account)

      report_purge_barrier(account_subscription, stripe_subscription)
    end

    # A Checkout that was started before the move and finished after it (review
    # 7, D50 D3).
    #
    # Checkout is created against the account that clicked and leaves no local
    # record of itself, so the move cannot see one in flight: the person
    # accepts the invitation, their old account is archived, and then the
    # Stripe tab they left open days ago completes. The webhook resolves the
    # archived account through the session's own reference and, before this,
    # handed it a live subscription — an account with nobody in it, quietly
    # charging a card every month with no page anybody can reach to stop it.
    #
    # The barrier above already refuses the ACCESS. This closes the money,
    # which is the half that actually costs the customer, and it does it
    # through the one cancel path this app already has: mark the subscription
    # at Stripe under the metadata key only our secret key can write, then
    # cancel it, then apply what Stripe says back onto the row
    # (Accounts::Deletion.cancel_subscription!). The marker it stamps is the
    # account-deletion one, and it is the right one here: it means "we ended
    # this, and the duplicate-refund machinery must never touch it" — the money
    # question is not one this code may answer on its own, so it is put to a
    # person in the alert instead.
    #
    # Best effort, deliberately. This runs inside a webhook whose whole job is
    # to write down what Stripe said; a Stripe outage on the cancel must not
    # turn that into a failed, retrying event that never records anything. The
    # alert has already gone out, the account has no paid access either way,
    # and the operator has the subscription id in front of them.
    def stop_charging_moved_away!(account_subscription)
      Accounts::Deletion.cancel_subscription!(account_subscription.account)
    rescue StandardError => e
      ErrorReport.error(e, account_id: account_subscription.account_id,
                           stripe_subscription_id: account_subscription.stripe_subscription_id)
    end

    def report_moved_away_barrier(account_subscription, stripe_subscription)
      subscription_id = field(stripe_subscription, :id)

      OperatorAlert.deliver(
        subject: 'Stripe subscription completed for an account that was moved away',
        body: "Account #{account_subscription.account_id} was archived when its only member joined another " \
              "team (Accounts::MoveUser), and Stripe now reports subscription #{subscription_id} as " \
              "#{field(stripe_subscription, :status)} — almost certainly a Checkout that was started before " \
              "the move and finished after it.\n\nThe account has NOT been given paid access, and the " \
              'subscription is being cancelled at Stripe under the account-deletion marker. Check whether the ' \
              'card was charged: nothing is refunded automatically for this case, and if a payment was taken ' \
              'for a month of service nobody can use, only a person can decide what goes back.'
      )

      ErrorReport.warning('stripe subscription applied to an account archived by a move',
                          account_id: account_subscription.account_id, stripe_subscription_id: subscription_id)
    end

    def paid_state?(stripe_subscription)
      Plans::PAID_ACCESS_STATES.include?(access_state_for(stripe_subscription))
    end

    def report_purge_barrier(account_subscription, stripe_subscription)
      subscription_id = field(stripe_subscription, :id)

      OperatorAlert.deliver(
        subject: 'Stripe subscription applied to an account being purged',
        body: "Account #{account_subscription.account_id} is being purged (or already is a tombstone), and " \
              "Stripe reports subscription #{subscription_id} as " \
              "#{field(stripe_subscription, :status)}. The account has NOT been given paid access back, but " \
              'the card may still be being charged — cancel the subscription at Stripe.'
      )

      ErrorReport.warning('stripe subscription applied to an account being purged',
                          account_id: account_subscription.account_id, stripe_subscription_id: subscription_id)
    end

    # A subscription with no item on OUR price is either a subscription that
    # belongs to something else or a price migration nobody told the app
    # about. The row keeps the seats and the price ids it already had — a
    # foreign item's quantity is not a seat count — and a human is told.
    def report_missing_price(account_subscription, stripe_subscription)
      ErrorReport.warning('stripe subscription has no item on our price',
                          account_id: account_subscription.account_id,
                          stripe_subscription_id: field(stripe_subscription, :id),
                          price_id: StripeBilling.price_id)
    end

    # Everything apply! would write, without writing it — reconciliation asks
    # for this and compares before it repairs.
    def attributes_for(account_subscription, stripe_subscription)
      item = price_item(stripe_subscription)
      period_start, period_end = period_for(stripe_subscription, item)
      trial_end = timestamp(field(stripe_subscription, :trial_end))
      status = field(stripe_subscription, :status).to_s
      # THE BARRIER (review batch 2, R2; review 7, D50 D3). Stripe's facts are
      # still written — the ids, the period, the status, so the money history
      # stays readable — but an account whose purge has been claimed, which is
      # already a tombstone, or which was archived when its only member joined
      # another team is never handed paid ACCESS back. Without this a webhook
      # arriving between the claim and the purge would put a half-emptied
      # account back on the paid plan, and the purge's own refusal ("it still
      # holds a live paid subscription") would then stop it finishing: the
      # account would sit part-destroyed and paying. The moved-away half is the
      # same shape with a different ending — an account with nobody left in it
      # acquiring a live subscription that nobody can ever cancel.
      #
      # A genuinely live subscription on a barred account is a money problem
      # rather than an access problem, and `report_barrier` says so to a
      # person. For the moved-away case the app can also end it (see
      # `stop_charging_moved_away!`); for a purge in flight only somebody at
      # Stripe can stop the card being charged, which is why the alert is the
      # whole of the answer there.
      access_state = barred?(account_subscription) ? 'cancelled' : access_state_for(stripe_subscription)

      {
        access_state:,
        status:,
        stripe_status: status,
        quantity: quantity_for(stripe_subscription, fallback: account_subscription.quantity),
        # Which subscription an account holds is the Linker's decision alone,
        # and it only ever changes one after confirming the old one is over:
        # applying a Stripe object must never repoint a live row.
        stripe_subscription_id: account_subscription.stripe_subscription_id.presence ||
          field(stripe_subscription, :id),
        stripe_customer_id: account_subscription.stripe_customer_id.presence ||
          customer_id(stripe_subscription),
        # No item on our price: keep what the row already knows rather than
        # writing a stranger's ids over it (see report_missing_price).
        stripe_item_id: item ? field(item, :id) : account_subscription.stripe_item_id,
        stripe_price_id: item ? price_id_of(item) : account_subscription.stripe_price_id,
        stripe_product_id: item ? product_id(price_of(item)) : account_subscription.stripe_product_id,
        current_period_start: period_start,
        current_period_end: period_end,
        # When the subscription actually ended — not the same as the end of
        # the period it was paid up to.
        ended_at: ended_at_for(account_subscription, stripe_subscription),
        trial_end:,
        # One trial per account, ever: the stamp is set the first time a
        # subscription with a trial is seen and never cleared afterwards.
        trial_used_at: account_subscription.trial_used_at || (trial_end && Time.current),
        past_due_since: past_due_since_for(account_subscription, access_state),
        cancel_at_period_end: truthy?(field(stripe_subscription, :cancel_at_period_end)),
        synced_at: Time.current
      }
    end

    # The dunning clock, derived from the state that was just applied rather
    # than from the kind of event that triggered the refresh: a stale
    # `invoice.paid` delivered after a newer failure must not stop a clock
    # that is still running, and a recovered account must not keep one.
    # Review-6 C7: `suspended` (Stripe `unpaid` / `paused`) is what a
    # past_due subscription becomes when the retries run out, so it KEEPS the
    # clock rather than resetting it — otherwise a past_due → unpaid →
    # past_due wobble would hand the customer a fresh 14 days every time.
    # Only a healthy state (or one that is over) clears it.
    def past_due_since_for(account_subscription, access_state)
      return account_subscription.past_due_since if access_state == 'suspended'
      return nil unless access_state == 'past_due'

      account_subscription.past_due_since || Time.current
    end

    # Is THIS ROW, as it stands right now, one the app counts as paid?
    def paid_row?(account_subscription)
      Plans::PAID_ACCESS_STATES.include?(account_subscription.access_state)
    end

    # When the paid access actually ended. Stripe names the moment for an
    # ordinary cancellation; it names nothing at all for the states that end
    # paid access without cancelling the subscription (`unpaid` and `paused`,
    # which become `suspended` here). The free month has to start somewhere
    # (D43, prospective counters), so on a row that WAS paid the moment is
    # stamped the first time this is seen and never moved afterwards —
    # otherwise every later webhook and every nightly reconciliation would
    # push the free month's start forward and hand the account its caps back.
    #
    # An account that was never paid is never stamped: a Checkout that never
    # completed (`incomplete` → cancelled) must not be a way to restart a free
    # month.
    def ended_at_for(account_subscription, stripe_subscription)
      # Still paid at Stripe: nothing has ended, and a stamp left by an
      # earlier subscription is cleared — this account is paying again. Asked
      # FIRST, so a subscription set to cancel at period end (Stripe already
      # names `canceled_at`, the moment the customer clicked) is not recorded
      # as having ended while it is still being paid for.
      return nil if paid_state?(stripe_subscription)

      # Already stamped, so it stays: "never moved afterwards" has to mean
      # that for Stripe's own dates too (checkpoint 7, P4). A row suspended
      # on the 10th and finally cancelled by Stripe on the 20th ended its
      # paid access on the 10th; letting `canceled_at` overwrite the stamp
      # moved the free month's start with it and forgave ten days of
      # completions that the sends counter had already charged for.
      return account_subscription.ended_at if account_subscription.ended_at

      timestamp(field(stripe_subscription, :ended_at)) ||
        timestamp(field(stripe_subscription, :canceled_at)) ||
        (paid_row?(account_subscription) ? Time.current : nil)
    end

    # Seats: the quantity on the items that sit on OUR price, and nothing
    # else. A subscription carrying only foreign items says nothing about how
    # many seats this account bought, so the caller's own count is kept
    # instead of a stranger's. Never below one seat.
    def quantity_for(stripe_subscription, fallback: 1)
      ours = items(stripe_subscription).select { |item| price_id_of(item) == StripeBilling.price_id.to_s }

      return [fallback.to_i, 1].max if ours.empty?

      [ours.sum { |item| field(item, :quantity).to_i }, 1].max
    end

    # In this API version the billing period lives on the subscription ITEM;
    # older versions carried it on the subscription itself. Read the item
    # first, fall back to the top-level keys when they are present.
    def period_for(stripe_subscription, item)
      start_at = timestamp(item && field(item, :current_period_start)) ||
                 timestamp(field(stripe_subscription, :current_period_start))
      end_at = timestamp(item && field(item, :current_period_end)) ||
               timestamp(field(stripe_subscription, :current_period_end))

      [start_at, end_at]
    end

    # The item on our price, or nil. Never a foreign item: substituting one
    # would write somebody else's price and product onto the row.
    def price_item(stripe_subscription)
      our_price = StripeBilling.price_id.to_s

      return nil if our_price.blank?

      items(stripe_subscription).find { |item| price_id_of(item) == our_price }
    end

    # `price` is the expanded object when we asked for it and a bare id string
    # when we did not; both name the same price.
    def price_id_of(item)
      price = price_of(item)

      (price.is_a?(String) ? price : field(price, :id)).to_s
    end

    def items(stripe_subscription)
      Array(field(field(stripe_subscription, :items), :data))
    end

    def price_of(item)
      field(item, :price) || field(item, :plan)
    end

    # `product` is a bare id unless the caller expanded it.
    def product_id(price)
      product = field(price, :product)

      product.is_a?(String) ? product : field(product, :id)
    end

    def customer_id(stripe_subscription)
      customer = field(stripe_subscription, :customer)

      customer.is_a?(String) ? customer : field(customer, :id)
    end

    # Reads a field off a Stripe::StripeObject or a plain Hash with either
    # symbol or string keys, so the same mapping serves live objects and
    # captured fixtures.
    def field(object, key)
      return nil if object.nil?

      value = object[key.to_sym] if object.respond_to?(:[])
      value = object[key.to_s] if value.nil? && object.respond_to?(:[])

      value
    rescue TypeError, NoMethodError
      nil
    end

    def timestamp(value)
      return nil if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.at(value.to_i)
    end

    def truthy?(value)
      value == true || value.to_s == 'true'
    end
  end
end
