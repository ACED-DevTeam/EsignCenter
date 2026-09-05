# frozen_string_literal: true

# The watermark an operator's Resume leaves behind (Session 10, review 8 A1).
#
# The automatic sending pause looks at the bounce rate of the last few
# deliveries. Resuming an account cleared the pause but left that window
# alone, so the very bounces that caused the pause were still in it: the next
# bounce re-paused the account instantly and the console's Resume button could
# not lift a `bounce_rate` pause at all. The stamp is where the window now
# starts — deliveries before a resume are history, not evidence.
class AddSendingResumedAtToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :sending_resumed_at, :datetime
  end
end
