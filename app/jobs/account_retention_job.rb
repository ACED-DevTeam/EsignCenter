# frozen_string_literal: true

# The retention clock's tick, once a night (config/schedule.yml).
#
# Warnings first, then purges: an account that is warned tonight may be
# purged tomorrow night, and never the other way round. Everything it does is
# idempotent — the warnings are deduped on a counter keyed to the date they
# are about, and a purge of an already-purged account is a no-op — so a
# missed night or a double run changes nothing.
#
# THE WHOLE SET, THROUGH ONE DOOR (review 8, C1/D2). This job used to name
# three of the sweeps by hand, and the export sweeps that Session 8 added —
# the seven-day expiry, the failed-file tidy-up and the recovery of a build
# whose worker died — were only in `Accounts::Retention.run!`, which nothing
# in production called. A ready export therefore stayed in the bucket for
# ever, and a row stuck on `running` shut the account's export door for good.
# `run!` owns the list now, so a sweep added there is a sweep that runs.
class AccountRetentionJob < ApplicationJob
  queue_as :default

  def perform
    SchedulerStamps.record!('account_retention') do
      Accounts::Retention.run!
    end
  end
end
