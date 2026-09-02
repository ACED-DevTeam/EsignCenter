# frozen_string_literal: true

# The ONE place specs spell how a customer account stops being paid, mirroring
# the account factory's :paid trait (spec/factories/accounts.rb). Session 5
# re-points both at the real plan model; spec/golden/gating_spec.rb keeps
# calling `downgrade_to_free!` unmodified.
module PlanHelpers
  def downgrade_to_free!(account)
    account.account_configs.where(key: AccountConfig::PLAN_STUB_KEY).destroy_all
  end
end

RSpec.configure do |config|
  config.include PlanHelpers
end
