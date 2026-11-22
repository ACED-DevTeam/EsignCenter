# frozen_string_literal: true

# The morning check of the social apps for the marketing page at /admin
# (config/schedule.yml), and what "Refresh now" on that page enqueues.
#
# Each app is checked on its own and a failure is written to that app's
# status row rather than raised (MarketingAdmin::Social.run!), so this job
# does not fail because YouTube did: retrying the whole run would only ask
# the apps that already answered a second time. The stamp is what the
# operator console's scheduler tab shows; which app failed, and why, is on
# the marketing page itself.
class MarketingSocialSnapshotJob < ApplicationJob
  STAMP = 'marketing_social_snapshot'

  queue_as :default

  def perform(trigger = MarketingAdmin::Social::CRON)
    SchedulerStamps.record!(STAMP) { MarketingAdmin::Social.run!(trigger:) }

    nil
  end
end
