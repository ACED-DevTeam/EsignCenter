# frozen_string_literal: true

# The billing clock's tick, hourly. Two sweeps, both idempotent, so a missed
# hour or a double run changes nothing:
#
#   * dunning — reminder emails through the 14-day grace period, and the
#     suspension at the end of it. Hourly rather than daily because "day 14"
#     decides whether an account can still send: on a daily job a customer
#     would keep sending for up to a day past it, and a customer who paid at
#     09:00 would still be suspended at 09:00 the next morning.
#
#   * invitations — a seat held for somebody who never arrived is handed back
#     when the invitation lapses, so the next invoice bills one fewer
#     (Session 7 Phase B).
class BillingLifecycleJob < ApplicationJob
  queue_as :billing

  def perform
    BillingLifecycle.run_dunning!
    BillingLifecycle.expire_invites!
  end
end
