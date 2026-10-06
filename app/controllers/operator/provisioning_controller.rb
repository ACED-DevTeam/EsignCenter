# frozen_string_literal: true

module Operator
  # Where accounts came from and where people went: the provisioning API's own
  # log, every "join this team" move, every invitation ever written, and the
  # subscriptions currently billing for more seats than are occupied.
  #
  # Read-only by construction. There is no door on this page that changes
  # anything — an invitation is cancelled from the account's own Users page,
  # and a seat is handed back by the hourly sweep, not by a button here.
  class ProvisioningController < BaseController
    # Seat occupancy is several queries per account, so the seat-drift panel
    # weighs a bounded slice of the paid rows and says when it had to stop.
    SEAT_SCAN_LIMIT = 200

    # The invitation states this tab can list. `payment_pending` is the one
    # worth the highlight: a seat purchase Stripe parked and has not applied,
    # which holds no seat and has mailed nobody until it is promoted
    # (checkpoint 7, B1).
    INVITE_STATES = %w[pending payment_pending expired released accepted revoked].freeze

    def show
      load_provisioning_events
      load_moves
      load_invites
      load_seat_drift
    end

    private

    # `q` searches the two things anybody ever has in hand when they ask about
    # a provisioned account: the address it was created for, and the
    # idempotency key the caller sent.
    def load_provisioning_events
      @query = params[:q].to_s.strip
      events = ProvisioningEvent.order(id: :desc).preload(account: :account_subscription)

      if @query.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
        events = events.where(ProvisioningEvent.arel_table[:email].matches(pattern)
                                .or(ProvisioningEvent.arel_table[:idempotency_key].matches(pattern)))
      end

      @pagy, @provisioning_events = pagy_auto(events)
    end

    def load_moves
      @moves = AccountMove.order(id: :desc).preload(:user, :from_account, :to_account).limit(50)
    end

    def load_invites
      @invite_state = params[:invite_state].to_s.presence_in(INVITE_STATES) || 'pending'
      @invite_counts = INVITE_STATES.index_with { |state| invites_in(state).count }

      @invites = invites_in(@invite_state).order(id: :desc).preload(:account, :invited_by).limit(100)
    end

    def invites_in(state)
      case state
      when 'pending' then AccountInvite.pending
      when 'payment_pending' then AccountInvite.payment_pending
      when 'expired' then AccountInvite.expired
      when 'released' then AccountInvite.where.not(released_at: nil)
      when 'accepted' then AccountInvite.where.not(accepted_at: nil)
      else AccountInvite.where.not(revoked_at: nil)
      end
    end

    # Seat reconciliation keeps nothing durable: BillingLifecycle's hand-back
    # reports a failure to ErrorReport and otherwise simply asks Stripe for
    # the seats back, so there is no table of "reconciliation events" to list.
    # What CAN be shown is the standing question it answers every hour — the
    # rows that are billing for more seats than their account occupies — read
    # from the subscription columns themselves. The page says the sweep is
    # what settles them.
    #
    # Occupancy is counted for the whole panel at once (review 1, M3).
    # `Accounts.seat_occupancy` is three or four queries per account, which
    # over a couple of hundred rows was the one real N+1 left in the console;
    # OperatorConsole.seats_by_billing answers the same question — the same
    # seat family, the same holders, the same pending invitations — for every
    # row in two.
    def load_seat_drift
      rows = AccountSubscription.where(access_state: Plans::PAID_ACCESS_STATES)
                                .where.not(stripe_subscription_id: nil)
                                .where.not(account_id: Account.testing_child_ids)
                                .preload(:account).order(id: :desc)
                                .limit(SEAT_SCAN_LIMIT + 1).to_a

      @seat_scan_truncated = rows.size > SEAT_SCAN_LIMIT
      rows = rows.first(SEAT_SCAN_LIMIT)
      occupancy = OperatorConsole.seats_by_billing(OperatorConsole.seat_family_ids(rows.map(&:account)))

      @seat_drift = rows.filter_map do |row|
        occupied = occupancy.fetch(row.account_id, 0)

        { row:, occupied: } if row.quantity > occupied
      end
    end
  end
end
