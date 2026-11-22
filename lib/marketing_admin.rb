# frozen_string_literal: true

# The private marketing page at /admin (docs/marketing-admin.md): who may open
# it, and the one clock every number on it is counted by.
#
# The page is for the people who run EsignCenter's marketing, not for
# customers and not for the platform operator's console. It is opened by
# email address: a signed-in, confirmed user whose address is on the list
# below and who created that login themselves. Everybody else — signed out
# or signed in — is answered with a 404, the same answer as a page that does
# not exist.
module MarketingAdmin
  # Days on the page are America/Chicago days, whatever timezone the server
  # or the viewer's account is in: "today" has to mean the same day for the
  # website counter, the social snapshots and the outreach numbers.
  TIME_ZONE = 'America/Chicago'

  EMAILS_ENV = 'MARKETING_ADMIN_EMAILS'

  module_function

  # The list lives only in MARKETING_ADMIN_EMAILS (comma-separated, any letter
  # case, spaces ignored), never in the source: the repository is public, so
  # no address is written down here. Unset or blank means the page opens for
  # nobody.
  def emails
    ENV.fetch(EMAILS_ENV, '').split(',').map { |email| email.strip.downcase }.compact_blank
  end

  # Is this address on the list?
  def listed?(user)
    user.present? && emails.include?(user.email.to_s.downcase)
  end

  # Four things, and the last two are what make the first two mean anything.
  #
  # Being on the list and being confirmed is NOT proof that the person owns
  # the mailbox. A login can be made FOR an address by somebody else: an
  # administrator of an internal account creates users with a password and no
  # confirmation step (UsersController#create_user_now), and so do the setup
  # page and the provisioning API. Whoever did that for a listed address that
  # has no login yet would hold a confirmed user with that address — and,
  # without the third line here, the page.
  #
  # So the login has to be one its owner made at a sign-up door, and there is
  # already a record of exactly that: the agreement to the Terms that every
  # self-serve sign-up writes in the same transaction as the user
  # (Registrations.save_signup), and that nothing else writes. A login created
  # any other way has no such row, and no later step gives it one.
  #
  # And the SESSION has to have been opened in a way that proves the person
  # using it is that owner today — MailboxProof explains why being signed in
  # is not that, and what counts. `warden` is the request's Warden proxy;
  # without one there is no session and therefore no proof.
  #
  # A changed address stays covered: it waits in `unconfirmed_email` until the
  # link mailed to the NEW address is opened, whoever asked for the change,
  # and a proof names the address it was given for.
  def allowed?(user, warden: nil)
    return false if user.nil? || user.archived_at?
    return false unless user.confirmed?
    return false unless listed?(user)
    return false unless signed_up_themselves?(user)

    MailboxProof.present?(warden, user)
  end

  # Asked only for an address on the list, so the navigation bar's "is this
  # person allowed?" costs everybody else no query at all.
  def signed_up_themselves?(user)
    LegalAcceptance.exists?(user_id: user.id, source: Registrations::SELF_SERVE_SOURCES)
  end

  def today(now = Time.current)
    now.in_time_zone(TIME_ZONE).to_date
  end

  # The instants one Chicago day covers, for querying UTC timestamps.
  def day_range(first_day, last_day = first_day)
    zone = ActiveSupport::TimeZone[TIME_ZONE]

    start = zone.local(first_day.year, first_day.month, first_day.day)
    finish = zone.local(last_day.year, last_day.month, last_day.day) + 1.day

    start...finish
  end

  # A SQL expression for the Chicago day of a UTC timestamp column. Postgres
  # only, like the rest of this deployment (development and tests require it).
  def chicago_day_sql(column)
    "((#{column} AT TIME ZONE 'UTC') AT TIME ZONE '#{TIME_ZONE}')::date"
  end
end
