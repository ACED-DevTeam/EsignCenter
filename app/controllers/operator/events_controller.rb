# frozen_string_literal: true

module Operator
  # The audit log: every change the console has ever made, newest first.
  #
  # Read-only by construction — there is no door here that writes an
  # OperatorEvent, because the rows are written by the actions themselves,
  # inside the transaction that made the change (lib/operator_events.rb).
  class EventsController < BaseController
    def index
      @account = console_accounts.find_by(id: params[:account_id]) if params[:account_id].present?
      @action_filter = params[:event_action].to_s.presence
      @actions = OperatorEvent::ACTIONS

      events = OperatorEvent.newest_first.preload(:operator, :account)
      events = events.where(account_id: @account.id) if @account
      events = events.where(action: @action_filter) if @action_filter.in?(OperatorEvent::ACTIONS)

      @pagy, @events = pagy_auto(events)
    end
  end
end
