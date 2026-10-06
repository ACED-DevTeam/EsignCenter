# frozen_string_literal: true

# The ONE place specs spell how a customer account stops being paid, mirroring
# the account factory's :paid trait (spec/factories/accounts.rb): the
# subscription row flips to cancelled and stays (a downgrade never purges, D43).
#
# It leaves the same trail every real downgrade leaves — StripeBilling::
# SubscriptionSync for a Stripe cancellation, `rake plans:revoke` for a
# hand-revoke — so a spec that downgrades reads the counters a customer would
# actually see: the free month starts where the paid one stopped (`ended_at`)
# and the send counter's value at that instant is written down
# (Quotas.record_downgrade!, D43 prospective counters).
module PlanHelpers
  def downgrade_to_free!(account)
    subscription = account.account_subscription

    return if subscription.nil?

    # Read before the write, and never stamp a row that was not paid: a
    # cancelled or incomplete row must not be able to restart a free month.
    was_paid = Plans.paid_subscription?(account)
    ended = was_paid ? { ended_at: subscription.ended_at || Time.current } : {}

    ApplicationRecord.transaction do
      subscription.update!(access_state: 'cancelled', status: 'canceled', cancel_at_period_end: false,
                           cancel_at: nil, **ended)

      Quotas.record_downgrade!(account) if was_paid
    end
  end
end

RSpec.configure do |config|
  config.include PlanHelpers
end
