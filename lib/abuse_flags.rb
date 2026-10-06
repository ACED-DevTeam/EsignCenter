# frozen_string_literal: true

# The one writer of AbuseFlag rows. A flag with a period is recorded at most
# once per (account, kind, period) — a second call returns the existing row —
# so the engine can call it on every completion without a guard of its own.
# A second incident after the operator resolved the row in the same period
# reopens it (details merged), so a resolved flag never hides a new one.
# The create runs in a savepoint: a unique-index conflict must not poison the
# caller's transaction (creation paths call this inside the creation lock).
module AbuseFlags
  module_function

  def record!(account, kind, period: '', subject: nil, details: {})
    AbuseFlag.transaction(requires_new: true) do
      AbuseFlag.create!(account:, kind:, period:, subject:, details:)
    end
  rescue ActiveRecord::RecordNotUnique
    reopen(AbuseFlag.find_by!(account:, kind:, period:), subject:, details:)
  end

  def reopen(flag, subject:, details:)
    return flag if flag.resolved_at.nil?

    flag.update!(resolved_at: nil,
                 subject: flag.subject || subject,
                 details: flag.details.merge(details.deep_stringify_keys))

    flag
  end
end
