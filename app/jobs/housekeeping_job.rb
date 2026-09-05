# frozen_string_literal: true

# The hourly tidy-up (config/schedule.yml), for the things that EXPIRE on a
# clock and belong to no other sweep's business.
#
# Two of them today, and they are here for the same reason: both are states
# that end by themselves, and until something writes that ending down the app
# tells the customer something that is no longer true.
#
#   * an abandoned support session. It is over — nothing the operator does
#     after the hour is honoured — but the audit row that says so is written
#     by the operator's NEXT request, and somebody who closes the browser
#     never makes one. Until this sweep the customer's Support-access card
#     said "In progress" for ever (Session 8 walk finding 2);
#   * a Postmark webhook parked because it arrived before its own send row
#     (review 8, D8). Nearly all of them are attributed within the second, by
#     the observer that writes that row; this is the backstop for the ones
#     that are not, and the one thing that drops a parked event that no send
#     row is ever going to claim.
#
# Every sweep runs on every tick and a failure in one is not allowed to stop
# the others — a broken webhook replay must not leave support sessions open —
# so each is called through `run!` and reports on its own. The stamp is what
# the operator console's scheduler tab shows.
class HousekeepingJob < ApplicationJob
  queue_as :default

  # Named so the golden spec can assert the list rather than the calls: a
  # sweep quietly dropped from here is a sweep that silently stops happening.
  SWEEPS = %i[expire_support_sessions! sweep_pending_email_events!].freeze

  def perform
    SchedulerStamps.record!('housekeeping') { run! }

    nil
  end

  def run!
    SWEEPS.index_with { |sweep| send(sweep) }
  end

  private

  def expire_support_sessions!
    SupportImpersonation.expire_abandoned!
  rescue StandardError => e
    ErrorReport.error(e)

    nil
  end

  def sweep_pending_email_events!
    PostmarkWebhooks.sweep_pending!
  rescue StandardError => e
    ErrorReport.error(e)

    nil
  end
end
