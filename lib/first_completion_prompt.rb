# frozen_string_literal: true

# The one-time "your first document is signed" upgrade banner (D50).
#
# `Quotas.arm_first_completion_prompt` writes the AccountConfig row the first
# time a free account's very first document is signed; this decides who sees
# the banner it stands for, and the dashboards render it. There is no second
# copy of the rule.
module FirstCompletionPrompt
  KEY = AccountConfig::FIRST_COMPLETION_UPGRADE_PROMPT_KEY

  module_function

  # The armed, undismissed row for this signed-in person, or nil.
  #
  # Administrators only, and only of the account that is actually billed: the
  # banner is about buying a plan, so showing it to somebody who cannot buy
  # one — a member, or an administrator of a child account whose parent pays —
  # would be an invitation to a door that is shut. Free plans only, so an
  # account that has already upgraded is never asked to upgrade again.
  def for(account:, user:)
    return unless user.admin?
    return unless account.customer?
    return unless Plans.billing_account(account) == account
    return unless Plans.key_for(account) == Plans::FREE

    config = account.account_configs.find_by(key: KEY)

    return if config.nil? || config.value.to_h['dismissed_at'].present?

    config
  end
end
