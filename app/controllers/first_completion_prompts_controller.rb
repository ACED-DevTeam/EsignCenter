# frozen_string_literal: true

# Putting away the one-time "your first document is signed" banner (D50).
#
# The banner belongs to the ACCOUNT, not to the person: it is a message about
# the account's plan, so one administrator dismissing it puts it away for
# everybody who could have acted on it. The row it stamps is the same
# AccountConfig the quota engine armed, so a dismissal survives everything —
# a new browser, a new device, a month rollover.
class FirstCompletionPromptsController < ApplicationController
  def destroy
    config = AccountConfig.find_or_initialize_by(account_id: current_account.id,
                                                 key: AccountConfig::FIRST_COMPLETION_UPGRADE_PROMPT_KEY)

    authorize!(:update, config)

    # Nothing to dismiss is not an error — a second click, or a stale tab.
    # No row is written either: a dismissal of a banner that was never armed
    # must not silently cancel the one this account has yet to earn.
    config.update!(value: config.value.to_h.merge('dismissed_at' => Time.current.utc.iso8601)) if config.persisted?

    redirect_back(fallback_location: root_path)
  end
end
