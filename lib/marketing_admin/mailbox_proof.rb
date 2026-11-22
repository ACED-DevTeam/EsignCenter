# frozen_string_literal: true

module MarketingAdmin
  # How THIS sign-in was proven, kept in the signed-in session, for the
  # marketing page's gate (MarketingAdmin.allowed?).
  #
  # Why the page needs it. The app signs somebody in to an existing login
  # whenever Google or Apple vouches for the login's email address. For an
  # address those companies host themselves that is as good as it gets. For
  # any other address it is weaker than it looks: Google marks an address
  # "verified" when the Google account was created with it, and — Google's own
  # guidance says so — that mark can outlive the person's hold on the mailbox.
  # Somebody who once had the listed address, and still has the Google account
  # they made with it, would be signed in as the listed user. That is true of
  # a listed user who registered with a password too.
  #
  # So being signed in as a listed user is not enough for this page. The
  # session itself has to have been opened in a way that proves the person in
  # front of it is the one the list means:
  #
  #   * with the login's PASSWORD (and its two-factor code where there is
  #     one) — the credential its owner set;
  #   * by finishing a PASSWORD RESET — the link went to the mailbox minutes ago;
  #   * with GOOGLE, only when Google is the authority for the address: a
  #     gmail.com address, or a Google Workspace domain that matches the
  #     address (the ID token's `hd` claim);
  #   * with APPLE, only for an address Apple itself hosts.
  #
  # Anything else leaves no proof: a Google or Apple sign-in for an address
  # they merely once verified, a session restored from the remember-me cookie,
  # and every session that was already open before this existed. Those people
  # are signed in exactly as before — nothing about ordinary sign-in changes —
  # and get the page's ordinary 404 until they sign in again in one of the
  # ways above.
  #
  # The proof is written only for an address on the marketing list, so nobody
  # else's session gains so much as a key.
  module MailboxProof
    KEY = 'marketing_mailbox_proof'

    HOWS = [PASSWORD = 'password', PASSWORD_RESET = 'password_reset', GOOGLE = 'google', APPLE = 'apple'].freeze

    # A proof does not last for ever: a browser that restores its tabs can
    # keep one session alive for months.
    MAX_AGE = 30.days

    GMAIL_DOMAIN = 'gmail.com'
    # The mailboxes Apple hosts, its private relay forwards among them.
    APPLE_DOMAINS = %w[icloud.com me.com mac.com privaterelay.appleid.com].freeze

    module_function

    # Call after the user has been signed in. `warden` is the request's
    # Warden proxy.
    def record!(warden, user, how)
      return unless HOWS.include?(how) && MarketingAdmin.listed?(user)

      warden.session(:user)[KEY] = { 'user_id' => user.id, 'email' => user.email.to_s.downcase, 'how' => how,
                                     'at' => Time.current.to_i }
    rescue StandardError => e
      # Never a reason for a sign-in to fail: without a proof the page is a
      # 404, which is the safe side.
      ErrorReport.error(e)

      nil
    end

    # Every successful sign-in starts from no proof: whatever an earlier
    # sign-in in this browser left behind is wiped first, and only a sign-in
    # that itself qualifies writes a new one (`record!`, called after). Run
    # from a Warden hook on every authentication (config/initializers/
    # marketing_admin.rb) and by the Google/Apple callback before it signs in,
    # because Devise skips Warden entirely when the same login is already
    # signed in.
    def forget!(warden)
      return unless warden&.authenticated?(:user)

      warden.session(:user).delete(KEY)
    rescue StandardError => e
      ErrorReport.error(e)

      nil
    end

    # Is there a proof in this session, for THIS user at THIS address, that is
    # still fresh? A proof written for somebody else who used the browser
    # before, or for an address the login has since moved away from, is none.
    def present?(warden, user)
      proof = warden&.session(:user)&.[](KEY)

      proof.is_a?(Hash) && proof['user_id'] == user.id && proof['email'] == user.email.to_s.downcase &&
        HOWS.include?(proof['how']) && fresh?(proof['at'])
    rescue StandardError
      false
    end

    def fresh?(recorded_at)
      recorded_at.is_a?(Integer) && recorded_at <= Time.current.to_i && recorded_at > MAX_AGE.ago.to_i
    end

    # Google's rule for when its "verified" can be relied on: the address is
    # a gmail.com one, or the account belongs to a Google Workspace domain
    # (`hd`) — and here that domain has to be the address's own.
    def google_authoritative?(email, hosted_domain)
      domain = domain_of(email)

      return false if domain.blank?

      domain == GMAIL_DOMAIN || (hosted_domain.is_a?(String) && hosted_domain.strip.downcase == domain)
    end

    # Apple has no equivalent of `hd`. The only addresses it is the authority
    # for are its own.
    def apple_authoritative?(email)
      APPLE_DOMAINS.include?(domain_of(email))
    end

    def domain_of(email)
      email.to_s.strip.downcase.rpartition('@').last.presence if email.to_s.count('@') == 1
    end
  end
end
