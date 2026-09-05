# frozen_string_literal: true

# The sole writer of OperatorEvent rows.
#
# Every console mutation calls this from INSIDE the transaction that makes the
# change: an audit written afterwards is an audit that a crash, a rollback or
# a raised validation can silently skip, and "the account is suspended and
# nobody knows who did it" is the one outcome an operator console must never
# produce. Conversely a rolled-back change takes its audit row with it, so the
# log never claims something that did not happen.
#
# `operator:` may be nil, and only for the system: CompExpiryJob revoking a
# comp whose date passed is a real change with no human behind it.
module OperatorEvents
  module_function

  def record!(operator:, action:, account: nil, subject: nil, reason: nil, details: {}, request: nil)
    OperatorEvent.create!(
      operator:,
      account:,
      subject:,
      action: action.to_s,
      reason: reason.presence,
      details: normalize(details),
      ip: request&.remote_ip,
      created_at: Time.current
    )
  end

  # jsonb wants string keys, and a symbol-keyed hash written today reads back
  # string-keyed tomorrow — so it is normalized once, here, and every reader
  # can rely on one shape.
  def normalize(details)
    (details || {}).deep_stringify_keys
  end
end
