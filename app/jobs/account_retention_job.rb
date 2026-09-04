# frozen_string_literal: true

# The retention clock's tick, once a night (config/schedule.yml).
#
# Warnings first, then purges: an account that is warned tonight may be
# purged tomorrow night, and never the other way round. Everything it does is
# idempotent — the warnings are deduped on a counter keyed to the date they
# are about, and a purge of an already-purged account is a no-op — so a
# missed night or a double run changes nothing.
class AccountRetentionJob < ApplicationJob
  queue_as :default

  def perform
    Accounts::Retention.schedule_dormant_warnings!
    Accounts::Retention.schedule_deletion_reminders!
    Accounts::Retention.purge_due!
  end
end
