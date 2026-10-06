# frozen_string_literal: true

# Who is on the other end of a share link: the account's own signed-in user
# (the sender, opening their own link or signing it themselves), or an
# anonymous holder of the slug. Only the sender may be told the account's
# business state — which quota closed the link, the number it is, the date it
# resets — because only the sender can act on it and it is nobody else's
# business. Everyone else gets the generic refusal.
#
# Shared by the paused page and by the anonymous "email me a code" door, which
# refuse the same visitor for the same reason and so must answer alike.
module SenderViewing
  extend ActiveSupport::Concern

  private

  # Reads @template — every action that asks has already loaded it.
  def sender_viewing?
    current_user.present? && current_user.account_id == @template.account_id
  end
end
