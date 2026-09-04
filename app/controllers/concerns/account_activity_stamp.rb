# frozen_string_literal: true

# "This account is in use", recorded from the two controller hierarchies that
# can say it honestly (Accounts::Activity, review 8 F1).
#
# WHY IT IS A CONCERN RATHER THAN TWO LINES IN TWO PLACES: the browser
# (ApplicationController) and the REST API (Api::ApiBaseController) descend
# from different superclasses but have to answer the same question the same
# way, and the answer has one subtlety worth writing down once — see
# `impersonating?` below.
#
# BOTH CALLERS INVOKE THIS FROM `authenticate_user!`, never from a callback of
# their own. That is the whole reason signer and public traffic cannot be
# mistaken for an account's own activity: the twenty-odd controllers that
# serve the recipient of a document already `skip_before_action
# :authenticate_user!`, so they skip this with it, automatically and for ever.
# A separate `before_action` would have had to be skipped in every one of
# them, and one forgotten file would keep an abandoned account alive on the
# strength of a stranger opening a signing link.
module AccountActivityStamp
  private

  def record_account_activity!
    return if impersonating?

    Accounts::Activity.record!(current_account)
  end

  # Is this OUR traffic rather than the customer's? An operator impersonating
  # somebody must not silently restart that account's dormancy clock: only
  # the account's own people can honestly reset it.
  #
  # `true_user` is Pretender's "who is really signed in". It is deliberately
  # allowed to be nil: on the API, `current_user` also resolves from an
  # X-Auth-Token, and a token request has no Warden session and therefore no
  # `true_user` at all. Nil means "nobody is pretending to be anybody", which
  # is exactly the case we want to stamp.
  def impersonating?
    true_user.present? && true_user != current_user
  end
end
