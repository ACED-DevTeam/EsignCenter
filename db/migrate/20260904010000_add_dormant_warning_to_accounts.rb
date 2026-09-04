# frozen_string_literal: true

# Evidence that we warned somebody before deleting their unused account
# (review batch 2, K6).
#
# The dormant clock is COMPUTED — a year after the last sign-in — which is
# what makes a single sign-in reset it. But a computed clock has no memory of
# whether anybody was ever told, so an account that was already a year idle
# when this feature shipped (or that crossed its deadline while the scheduler
# was down) would be destroyed on the very first sweep, in silence.
#
# These two columns are that memory, and they are columns rather than a
# counter because they have to survive a Redis flush and a restart:
#
#   dormant_warning_sent_at — when the FINAL (7-day) warning actually went out.
#                             Nothing dormant is purged until this is at least
#                             7 days old.
#   dormant_warning_for     — the purge date that warning named, so a late
#                             account's deadline is pinned once instead of
#                             sliding a day further every night, and so the
#                             purge never happens before the date the customer
#                             was given.
class AddDormantWarningToAccounts < ActiveRecord::Migration[8.1]
  def change
    change_table :accounts, bulk: true do |t|
      t.datetime :dormant_warning_sent_at
      t.datetime :dormant_warning_for
    end
  end
end
