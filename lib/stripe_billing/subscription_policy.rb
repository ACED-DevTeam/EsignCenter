# frozen_string_literal: true

module StripeBilling
  # The two questions the Linker, the Checkout door and the nightly sweep must
  # all answer the same way: is this Stripe subscription OURS, and when a
  # customer somehow holds several, which one does the account keep?
  #
  # A Stripe customer can carry subscriptions this app never sold — another
  # product on a shared Stripe account, something created by hand in the
  # dashboard. Those are never adopted (they would grant paid access for a
  # purchase that was not ours) and never cancelled (they are somebody's real
  # purchase). Pure functions over a Stripe::Subscription or a hash shaped
  # like one, so the specs can feed them captured fixtures.
  module SubscriptionPolicy
    # Stripe statuses under which a subscription is finished. Every other
    # status — trialing, active, past_due, unpaid, paused, incomplete — is a
    # subscription that can still charge somebody, so it counts as live.
    DEAD_STRIPE_STATUSES = %w[canceled incomplete_expired].freeze

    module_function

    def live?(stripe_subscription)
      live_status?(SubscriptionSync.field(stripe_subscription, :status))
    end

    # Explicitly over, as opposed to "not known to be live": a blank status
    # is neither, and nothing money-related may be decided on it.
    def dead?(stripe_subscription)
      DEAD_STRIPE_STATUSES.include?(SubscriptionSync.field(stripe_subscription, :status).to_s)
    end

    def live_status?(status)
      status.to_s.present? && DEAD_STRIPE_STATUSES.exclude?(status.to_s)
    end

    # Ours when it carries an item on the price this app sells, or when our
    # own Checkout tagged it with this account's id.
    def ours?(stripe_subscription, account_id)
      on_our_price?(stripe_subscription) || tagged_account_id(stripe_subscription) == account_id.to_s
    end

    # Never true while no price is configured: "" would match an item with
    # no price at all and make a stranger's subscription ours.
    def on_our_price?(stripe_subscription)
      StripeBilling.price_id.present? && SubscriptionSync.price_item(stripe_subscription).present?
    end

    # The account id our Checkout writes into `subscription_data.metadata`;
    # blank on anything we did not create.
    def tagged_account_id(stripe_subscription)
      SubscriptionSync.field(SubscriptionSync.field(stripe_subscription, :metadata), :account_id).to_s
    end

    # How well a live subscription is actually collecting. Age alone is not
    # enough to pick a survivor: an `incomplete` subscription (abandoned 3-D
    # Secure) has never taken a cent and never will, and one in dunning is
    # only trying — so neither may beat one that is genuinely charging the
    # card, however much older it is. Cancelling the collecting one and
    # keeping the sick one costs the customer their access AND refunds us to
    # zero.
    COLLECTING_STRIPE_STATUSES = %w[active trialing].freeze
    DUNNING_STRIPE_STATUSES = %w[past_due unpaid paused].freeze

    def health_rank(stripe_subscription)
      case SubscriptionSync.field(stripe_subscription, :status).to_s
      when *COLLECTING_STRIPE_STATUSES then 0
      when *DUNNING_STRIPE_STATUSES then 1
      else 2
      end
    end

    # Which of several live subscriptions the account keeps, in three steps:
    #
    #   1. HEALTH first (health_rank): the one that is actually collecting
    #      beats one Stripe is still dunning, which beats one that has never
    #      charged at all;
    #   2. then OUR PRICE: between two equally healthy ones, the one carrying
    #      an item on the price we sell beats one that is merely tagged with
    #      the account id;
    #   3. then the EARLIEST created — it has been charging longest and is
    #      the one the customer most likely knows about.
    #
    # Everything after the first is a duplicate. Deterministic, so two
    # workers reach the same answer.
    #
    # Health used to come SECOND, and that was the bug (Review 6 N3): an
    # `incomplete` subscription on our price — an abandoned card confirmation
    # that has never taken a cent and never will — beat a `trialing` one that
    # our own Checkout had tagged but whose price we could not read. The
    # collecting subscription was then cancelled as the "duplicate" and
    # refunded, and the account was left holding the one that cannot pay:
    # free plan, API off, money returned. Whether a subscription can collect
    # is the fact that decides who the customer is; which price it sits on
    # only decides which of two equally healthy ones is more likely ours.
    def survivor_order(subscriptions)
      subscriptions.sort_by do |subscription|
        [health_rank(subscription),
         on_our_price?(subscription) ? 0 : 1,
         SubscriptionSync.field(subscription, :created).to_i,
         SubscriptionSync.field(subscription, :id).to_s]
      end
    end
  end
end
