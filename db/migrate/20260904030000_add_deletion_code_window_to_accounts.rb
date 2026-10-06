# frozen_string_literal: true

# Guesses are counted per WINDOW, not per code (review batch 2 loop 3, R6).
#
# Asking for a fresh code used to reset `deletion_code_attempts` to zero, so
# the five-guess budget could be lifted simply by pressing "Email me a
# confirmation code" again — and the only thing standing in the way of that
# was a Redis rate limit, which fails open when Redis is unreachable. The
# budget now spans a 30-minute window that a re-issue does not restart, and
# this column is where that window begins.
class AddDeletionCodeWindowToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :deletion_code_window_started_at, :datetime
  end
end
