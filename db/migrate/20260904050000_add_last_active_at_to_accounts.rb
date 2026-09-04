# frozen_string_literal: true

# "Somebody is actually using this account" (review 8, F1).
#
# The dormant purge — the one action in this application that cannot be undone
# — measured a year of silence entirely out of Devise: the account's creation
# date, `users.current_sign_in_at`, `users.last_sign_in_at`, and the date the
# subscription ended. Every one of those is a fact about AUTHENTICATION, and
# this application deliberately asks for authentication almost never: sign-up
# turns remember-me on for everybody (User#remember_me) and the remember
# cookie lives for two years (config/initializers/devise.rb). So a person
# could open the app every morning for a year without once moving a Devise
# timestamp, and the account would be warned and then destroyed underneath
# them — while the warning letter told them to "simply sign in", which is
# precisely the thing a browser that is already signed in never does.
#
# This column is the missing fact: the last time a signed-in MEMBER of the
# account made a request the application required authentication for. It is
# written at most once a day (Accounts::Activity) and read as one more floor
# under Accounts::Retention.last_activity_at.
#
# NULLABLE, AND EXISTING ROWS ARE LEFT NULL ON PURPOSE.
#
# Nothing is backfilled with a value, because there is no honest value to
# backfill: we did not record this before today. NULL contributes nothing to
# the maximum that `last_activity_at` takes, so every account's dormancy
# clock reads exactly as it did yesterday — an account that really is
# abandoned stays on its schedule, and no account is handed a free year it
# did not earn by being used.
#
# The one thing that IS reset is the warning evidence. An account already
# part-way through its 60/30/7-day notice was measured under a definition of
# "unused" we now know to be wrong, and its 7-day letter could authorise a
# purge on the first night after this ships — before anybody using it has had
# a single request in which to be stamped. So the in-flight warnings are
# cleared: those accounts start their notice period again, under the new
# definition, and any of them that is genuinely being used will stamp itself
# long before the new letters run out. The cost is one repeated set of
# warning emails to accounts that really are abandoned; the alternative is
# deleting a live customer's account in the deployment window.
class AddLastActiveAtToAccounts < ActiveRecord::Migration[8.1]
  def up
    add_column :accounts, :last_active_at, :datetime

    execute(<<~SQL.squish)
      UPDATE accounts
         SET dormant_warning_sent_at = NULL,
             dormant_warning_for = NULL
       WHERE dormant_warning_sent_at IS NOT NULL
          OR dormant_warning_for IS NOT NULL
    SQL
  end

  def down
    remove_column :accounts, :last_active_at
  end
end
