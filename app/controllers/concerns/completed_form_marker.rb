# frozen_string_literal: true

# "This browser is one that completed that document."
#
# The share link's completed page (StartFormController#completed) names a
# document and the day it was signed, and it will only do that for somebody who
# can show the address they typed is theirs. There are two ways to show it. One
# is the emailed one-time code, which proves an address by sending something to
# it. The other is this marker, which the signer earns without being asked
# anything at all: the browser that ACTUALLY completed the form is handed it at
# the moment it completes, in the signer's own session.
#
# It used to be inferred instead — the visitor's IP address matching the one
# recorded on the completed submitter. That is not identity. An office, a
# household, a hotel, a school, a mobile carrier's NAT or a VPN exit puts
# hundreds of unrelated people behind one address, so anybody sharing a public
# IP with a signer could type that signer's email into the share link and be
# told, by document name and date, what they had signed. The document itself
# was never exposed, but "did Jane sign the settlement agreement, and when" is
# the sensitive part of a signature. Proof of an address now comes only from
# the address (the code) or from the person's own signing session (here).
#
# The marker names SUBMITTERS by slug, and the page demands both the marker and
# the address in the URL, so a marker earned on one document can never be spent
# asking about somebody else's. It holds a short LIST rather than a single
# slug: signing two documents from one browser must not turn the first of them
# back into a stranger. Oldest entries fall off the end.
module CompletedFormMarker
  extend ActiveSupport::Concern

  COOKIE = :completed_submitter_slug
  # Long enough for the signer to finish, close the tab and come back the same
  # day; short enough that a shared or borrowed browser does not carry the
  # proof around indefinitely. After it lapses they get the neutral page, which
  # still offers to email a copy to the address they typed.
  TTL = 12.hours
  MAX_SLUGS = 10
  DEFAULTS = { httponly: true, secure: Rails.env.production? }.freeze

  private

  # Called on the real completion path only — the request that completes the
  # form, and the completed page of a document whose own signing link this
  # browser is holding. Both are the signer's own session; neither takes the
  # visitor's word for anything.
  def remember_completed_form(submitter)
    return if submitter&.slug.blank?
    return unless submitter.completed_at?

    slugs = ([submitter.slug] | completed_form_slugs).first(MAX_SLUGS)

    cookies.encrypted[COOKIE] = { value: slugs, expires: TTL.from_now, **DEFAULTS }
  end

  # Array() so a cookie written before this was a list (a single slug) still
  # reads back as the proof it was.
  def completed_form_slugs
    Array(cookies.encrypted[COOKIE]).map(&:to_s).compact_blank
  end
end
