# frozen_string_literal: true

# The three paid thresholds that had no override column (Session 8).
#
# A free account's caps have been overridable since Session 5. A PAID
# account's numbers are not caps — they never block anything (D42) — but they
# are what raises a fair-use review flag, a send-velocity flag and an
# in-flight flag, and until now the operator could only move them by editing
# a constant and deploying. A customer with one seat and a genuine mail-merge
# season therefore produced a flag a night that nobody could turn off.
#
# All three are per-seat and nullable, and a NULL column means exactly what it
# means for every other override: use the plan default
# (Quotas::Limits::PAID_COMPLETIONS_REVIEW_PER_SEAT, PAID_SENDS_PER_DAY_PER_SEAT,
# PAID_IN_FLIGHT_PER_SEAT). Nothing about the rows already in the table changes.
class AddPaidThresholdsToAccountLimitOverrides < ActiveRecord::Migration[8.1]
  def change
    add_column :account_limit_overrides, :fair_use_per_seat, :integer
    add_column :account_limit_overrides, :sends_per_day_per_seat, :integer
    add_column :account_limit_overrides, :in_flight_per_seat, :integer
  end
end
