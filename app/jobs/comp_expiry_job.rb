# frozen_string_literal: true

# The comp clock, hourly (config/schedule.yml).
#
# A comp is paid access the operator gave away, and every comp carries the
# date it ends (account_subscriptions.comp_expires_at). This is what actually
# ends it: the same revoke path a hand-revoke and the console's Revoke button
# take, so a comp running out leaves exactly the trail a cancellation does —
# the row stays, the free month starts HERE rather than on the 1st (D43,
# prospective counters), and an OperatorEvent says what happened.
#
# The audit row names no human, because none pressed anything: it is written
# with `operator: nil` and the console prints it as "the system".
#
# Idempotent, so a missed hour or a double run changes nothing: revoking
# clears `comp_expires_at`, and an account that is already free simply stops
# matching. Every account is settled on its own — one refusal must not stop
# the sweep from reaching the rest.
class CompExpiryJob < ApplicationJob
  queue_as :billing

  def perform
    SchedulerStamps.record!('comp_expiry') do
      Plans::Manual.due_comps.find_each { |subscription| expire(subscription) }
    end

    nil
  end

  private

  # The decision is re-made under the row lock, not here: the query that
  # chose this row ran minutes ago, and an operator can have extended the comp
  # since (Plans::Manual.revoke_expired_comp!). A row that is no longer a comp
  # whose date has passed comes back nil and is left alone — including its
  # audit line, which must never claim a change that did not happen.
  def expire(subscription)
    account = subscription.account

    ApplicationRecord.transaction do
      revoked = Plans::Manual.revoke_expired_comp!(account)

      next settle_left_alone(subscription) if revoked.nil?

      OperatorEvents.record!(operator: nil, action: 'comp.expire', account:,
                             details: { comp_expires_at: subscription.comp_expires_at&.iso8601,
                                        plan: Plans.key_for(account.reload) })
    end
  rescue Plans::Manual::Refused => e
    ErrorReport.warning("comp expiry left alone for account #{subscription.account_id}: #{e.message}",
                        account_id: subscription.account_id)

    settle_left_alone(subscription)
  end

  # The sweep looked at this row under the lock and did not revoke it. Two
  # reasons, and only one of them needs anything doing:
  #
  #   * the comp was EXTENDED between the query and the lock, so the date is
  #     in the future again — nothing to do, and nothing to log;
  #   * the customer bought a real subscription while the comp was running, so
  #     Stripe is driving the row now and the comp is moot. The date is
  #     cleared, or the sweep would re-read this row every hour for ever.
  def settle_left_alone(subscription)
    subscription.reload

    return if subscription.comp_expires_at.blank? || subscription.comp_expires_at > Time.current
    return unless Plans::Manual.stripe_backed?(subscription)

    subscription.update!(comp_expires_at: nil)

    ErrorReport.info('comp superseded by a Stripe subscription; expiry date cleared',
                     account_id: subscription.account_id)
  end
end
