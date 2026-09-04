# frozen_string_literal: true

# The dunning clock's tick. Hourly rather than daily, because "day 14" is a
# deadline that decides whether an account can still send: on a daily job a
# customer would keep sending for up to a day past it, and a customer who
# paid at 09:00 would still be suspended at 09:00 the next morning.
# Everything it does is idempotent (BillingLifecycle), so a missed hour or a
# double run changes nothing.
class BillingDunningJob < ApplicationJob
  queue_as :billing

  def perform
    BillingLifecycle.run_dunning!
  end
end
