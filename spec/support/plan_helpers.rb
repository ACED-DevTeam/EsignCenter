# frozen_string_literal: true

# The ONE place specs spell how a customer account stops being paid, mirroring
# the account factory's :paid trait (spec/factories/accounts.rb): the
# subscription row flips to cancelled and stays (a downgrade never purges, D43).
module PlanHelpers
  def downgrade_to_free!(account)
    account.account_subscription&.update!(access_state: 'cancelled', status: 'canceled', cancel_at_period_end: false)
  end
end

RSpec.configure do |config|
  config.include PlanHelpers
end
