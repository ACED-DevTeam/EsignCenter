# frozen_string_literal: true

# The marketing page at /admin opens only for a listed address whose login was
# made by its owner at a sign-up door, in a session opened in a way that proves
# who is using it (MarketingAdmin.allowed?, MarketingAdmin::MailboxProof). A
# spec that needs somebody who can really get in says so with these.
module MarketingAdminHelpers
  # What marks a login as its owner's own: the agreement every self-serve
  # sign-up records.
  def signed_up_themselves(user, source: LegalAcceptance::SIGNUP_EMAIL)
    LegalDocuments.record_acceptance!(
      user, request: nil, source:, versions: LegalDocuments.submitted_versions(LegalDocuments.version_fields)
    )

    user
  end

  # The real sign-in form, with the factory's password. Devise's `sign_in`
  # test helper puts a user in the session without anybody proving anything,
  # which is exactly the kind of session the marketing page refuses.
  def sign_in_with_password(user, password: 'password')
    post user_session_path, params: { user: { email: user.email, password: } }

    expect(controller.current_user).to eq(user)
  end

  # A Warden session holding a proof for this user, for asking the list
  # directly (MarketingAdmin.allowed?) about everything BUT the proof.
  def session_proving(user, how: MarketingAdmin::MailboxProof::PASSWORD, at: Time.current)
    proof = { 'user_id' => user.id, 'email' => user.email.downcase, 'how' => how, 'at' => at.to_i }

    instance_double(Warden::Proxy, session: { MarketingAdmin::MailboxProof::KEY => proof })
  end

  # The real sign-out: it also throws away the remember-me cookie, which would
  # otherwise sign the same person straight back in on the next request.
  def sign_out_for_real
    delete destroy_user_session_path
  end
end

RSpec.configure { |config| config.include MarketingAdminHelpers, type: :request }
