# frozen_string_literal: true

require 'erb'

# The Terms of Service and the Privacy Policy: where the words live, how a
# rewrite is versioned, and what is written down when somebody agrees to them
# (docs/legal.md).
#
# The words themselves are ERB templates under config/legal, rendered with the
# product's own constants — the quota numbers, the seat price, the trial
# length — rather than with figures typed into the prose. A legal document
# that repeats a number the code owns will eventually disagree with it, and a
# Terms of Service that promises the wrong allowance is worse than no Terms at
# all. So the numbers are interpolated, and `spec/golden/legal_spec.rb` pins
# them against the same constants.
#
# The version/archive rule is the one EsignConsent already uses for the
# signer's disclosure (lib/esign_consent.rb): a recorded agreement is only
# worth having if the exact words behind it can still be produced years later.
# So every acceptance row stores the version AND the SHA-256 of the rendered
# text, any wording change bumps `version` (and `effective_on`), and the
# superseded HTML is archived verbatim under
# config/legal/archive/<doc>-<version>.html. `html(doc, version:)` reads it
# back, and its digest still matches what was written down.
#
# Rendering is deterministic on purpose: nothing time-dependent goes into a
# template, so the same version always produces the same bytes and therefore
# the same digest, whenever and wherever it is rendered.
module LegalDocuments
  # The live version of each document, the digest of the text that version
  # publishes, and the digest of every superseded text still in the archive.
  #
  # `sha256` is the whole point of writing the version down: it is checked
  # against the live render in spec/golden/legal_spec.rb, so ANY wording edit
  # — a corrected typo included — turns the suite red until the author bumps
  # the version, archives the old text and records the new digest here. The
  # procedure in docs/legal.md is therefore enforced rather than remembered.
  #
  # `archived` is the same promise for the past: `html(doc, version:)` reads a
  # superseded text back out of config/legal/archive and refuses it unless it
  # still hashes to the digest recorded on the day it was published.
  DOCUMENTS = {
    terms: {
      version: '2026-09-24',
      effective_on: Date.new(2026, 9, 24),
      sha256: '77a68c64156f26742a4bede94ac5fadf73eb0eb8179daabb9526cacd82524842',
      archived: {
        '2026-09-05' => '0373405efc70654fa0f0fed41caf7281ea925402406d091bf68a93153b78d3de',
        '2026-09-23' => 'ecc0015b0000da5ed3d1c5a282b7014aa25c732fe49cfd21b60aa769b8611577'
      }.freeze
    }.freeze,
    privacy: {
      version: '2026-09-23',
      effective_on: Date.new(2026, 9, 23),
      sha256: '4e1eed5cb3fc050655d489a94b0d40a9ac13b4a916032ab4630bac9f658050f2',
      archived: {
        '2026-09-05' => '1be7833ba2a2ff38d2b7a5018e45146510a304ddd59f5d3f826488086d52243e',
        '2026-09-06' => 'c8ea3037ba549f7e97b495e3290253ab799ceead6648606faa374ffad7d2c42c'
      }.freeze
    }.freeze
  }.freeze

  TEMPLATE_DIR = Rails.root.join('config/legal')
  ARCHIVE_DIR = Rails.root.join('config/legal/archive')

  # A version is a date. Enforced rather than assumed: it is the only part of
  # an archive filename that does not come from this file's own constants, and
  # a row read back out of the database must never be able to name a path.
  VERSION_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

  # The form sends back the version of each document it displayed, in a hidden
  # field (or, for the Google button, on the authorize request's query string
  # the way the timezone rides). The name is prefixed so one convention covers
  # a form field, a query parameter and an OmniAuth callback alike.
  VERSION_PARAM_PREFIX = 'legal_version_'

  # The page showed a version that is no longer the current one — or sent none
  # at all. Either way we cannot honestly write down that this person agreed
  # to the text we publish now, because it is not the text they read. Exactly
  # the rule EsignConsent applies to a signer's disclosure
  # (EsignConsent::StaleVersionError), for exactly the same reason.
  StaleVersionError = Class.new(StandardError)

  # An archived text is on disk but no longer hashes to the digest recorded
  # beside its version. Either the file was edited or the digest was, and
  # there is no honest way to tell which — so the text is refused loudly
  # rather than served as the words somebody agreed to.
  ArchiveMismatchError = Class.new(StandardError)

  # The public site the documents talk about themselves in. Not derived from
  # the request: the words must read the same in an archived copy as they did
  # on the day, whatever host happened to serve them.
  SITE_HOST = 'esigncenter.com'

  # Operator identity confirmed by Evan on 2026-09-23. Changing either value
  # requires archiving and versioning both documents (docs/legal.md).
  OPERATOR_LEGAL_NAME = 'EsignCenter LLC'
  # A postal address is not decoration: US commercial email law requires a
  # physical mailing address on the notices we send, and both documents point
  # at this one.
  OPERATOR_POSTAL_ADDRESS = '1911 S National Ave STE 104, Springfield, MO 65802'
  GOVERNING_LAW_STATE = 'Missouri'

  module_function

  def documents
    DOCUMENTS.keys
  end

  def known?(doc)
    DOCUMENTS.key?(doc.to_sym)
  end

  def version(doc)
    DOCUMENTS.dig(doc.to_sym, :version)
  end

  def effective_on(doc)
    DOCUMENTS.dig(doc.to_sym, :effective_on)
  end

  # The versions published right now, keyed by document.
  def current_versions
    DOCUMENTS.transform_values { |meta| meta[:version] }
  end

  # What a form has to send back: field name => the version it is displaying.
  def version_fields
    DOCUMENTS.each_key.to_h { |doc| ["#{VERSION_PARAM_PREFIX}#{doc}", version(doc)] }
  end

  # The versions a request claims to have displayed, read out of any params-ish
  # hash — a form body, an OmniAuth callback's `omniauth.params`. A document
  # the request said nothing about comes back nil, which `assert_current!`
  # treats as stale: an old client that has never heard of these fields must
  # not be able to opt out of the check by staying silent.
  def submitted_versions(params)
    DOCUMENTS.each_key.index_with { |doc| params&.[]("#{VERSION_PARAM_PREFIX}#{doc}").presence }
  end

  # Did this person read the text we are about to write down? Raises
  # StaleVersionError when they did not, so the caller can say so in a
  # sentence and show them the new one, rather than recording an agreement to
  # words nobody ever saw.
  def assert_current!(versions)
    versions = (versions || {}).symbolize_keys

    DOCUMENTS.each_key do |doc|
      raise StaleVersionError, 'legal_version_stale' unless versions[doc].to_s == version(doc)
    end

    true
  end

  # The same question without the exception, for a controller that wants to
  # refuse politely before it opens a transaction.
  def current_versions?(versions)
    assert_current!(versions)
  rescue StaleVersionError
    false
  end

  # The rendered HTML of a document. Without `version:`, the live one; with a
  # superseded version, the archived text of that version. nil for a document
  # this module does not publish, and for a version that was never archived.
  def html(doc, version: nil)
    doc = doc.to_sym

    return nil unless DOCUMENTS.key?(doc)
    return render(doc) if version.nil? || version.to_s == DOCUMENTS[doc][:version]

    archived(doc, version)
  end

  # What an acceptance row's `sha256` holds: the digest of exactly the bytes
  # the page showed.
  def sha256(doc, version: nil)
    text = html(doc, version:)

    Digest::SHA256.hexdigest(text) if text
  end

  # Every document this person agreed to when they made their login, written
  # in whatever transaction the caller is already in — the user save at
  # sign-up, the invitation's row lock at acceptance — so a sign-up that fails
  # afterwards leaves neither a user nor an agreement behind.
  #
  # `request` is optional because not every login is made by a browser: a
  # console-created or provisioned user has no request, and a row with no IP
  # is a truer record than a fabricated one.
  # `versions` is what the page the person was looking at said it was showing.
  # It is checked here as well as at the door, because this is the line that
  # writes the digest: a caller that forgets to ask must not be able to record
  # an agreement to a text the person never saw.
  def record_acceptance!(user, request:, source:, versions:)
    source = source.to_s

    raise ArgumentError, "Unknown acceptance source: #{source.inspect}" unless LegalAcceptance::SOURCES.include?(source)

    assert_current!(versions)

    accepted_at = Time.current

    DOCUMENTS.each_key.map do |doc|
      LegalAcceptance.create!(user:, account: user.account, document: doc.to_s, version: version(doc),
                              sha256: sha256(doc), accepted_at:, source:,
                              ip: request&.remote_ip, user_agent: user_agent_for(request))
    end
  end

  # Has this person agreed to the CURRENT version of everything? Nothing gates
  # on it yet; it is here so that whatever asks the question later asks it in
  # one place (a re-acceptance prompt after a bump, an admin report).
  def accepted_current?(user)
    return false if user.nil? || user.id.nil?

    DOCUMENTS.each_key.all? do |doc|
      LegalAcceptance.exists?(user_id: user.id, document: doc.to_s, version: version(doc))
    end
  end

  # A user agent is a header, which means it is whatever the client felt like
  # sending. The column exists to describe a browser, not to store an
  # arbitrary payload, so it is bounded here.
  def user_agent_for(request)
    request&.user_agent.to_s.first(512).presence
  end

  # Memoised per document AND version: the output is deterministic, so the
  # same pair can only ever produce the same bytes, and a sign-up used to
  # render both documents twice (once for each digest) inside the user's own
  # transaction. Two threads racing here both compute the identical string, so
  # there is nothing to lock. A bump changes the key; editing a template
  # in place does not, so a developer changing the wording restarts the
  # server (docs/legal.md).
  def render(doc)
    cache = (@render_cache ||= {})

    cache[[doc, DOCUMENTS[doc][:version]]] ||= render_now(doc)
  end

  def render_now(doc)
    template = TEMPLATE_DIR.join("#{doc}.html.erb").read

    ERB.new(template, trim_mode: '-').result_with_hash(assigns(doc)).freeze
  end

  # A superseded text, read back at the digest recorded beside its version.
  # nil for a version that was never published; ArchiveMismatchError for one
  # that was, but no longer matches — an archive nobody checks is not a record,
  # it is a file.
  def archived(doc, version)
    version = version.to_s

    return nil unless version.match?(VERSION_FORMAT)

    path = ARCHIVE_DIR.join("#{doc}-#{version}.html")

    return nil unless path.file?

    text = path.read
    expected = DOCUMENTS.dig(doc, :archived, version)

    if expected.blank? || Digest::SHA256.hexdigest(text) != expected
      raise ArchiveMismatchError, "#{doc} #{version} does not match its recorded digest"
    end

    text
  end

  # Everything a template may say. All of it constant: the digest of a
  # rendered document has to depend on the words and the code's own numbers,
  # and on nothing else.
  def assigns(doc)
    {
      product: Docuseal.product_name,
      site_host: SITE_HOST,
      operator_legal_name: OPERATOR_LEGAL_NAME,
      operator_postal_address: OPERATOR_POSTAL_ADDRESS,
      governing_law_state: GOVERNING_LAW_STATE,
      support_email: Docuseal::SUPPORT_EMAIL,
      github_url: Docuseal::GITHUB_URL,
      version: DOCUMENTS[doc][:version],
      effective_on: DOCUMENTS[doc][:effective_on],
      limits: Quotas::Limits,
      price: StripeBilling::PRICE_PER_SEAT_USD,
      trial_days: StripeBilling::TRIAL_PERIOD_DAYS,
      invite_days: BillingLifecycle::INVITE_TOKEN_DAYS,
      grace_days: BillingLifecycle::PAST_DUE_GRACE_DAYS,
      dunning_days: BillingLifecycle::DUNNING_DAYS,
      deletion_window_days: Accounts::Deletion::WINDOW_DAYS,
      dormant_warning_days: Accounts::Retention::DORMANT_WARNING_DAYS,
      paid_retention: duration_words(Accounts::Retention::PAID_RETENTION),
      dormant_after: duration_words(Accounts::Retention::DORMANT_AFTER),
      gigabytes: method(:gigabytes),
      sentence: method(:sentence)
    }
  end

  # "1 GB", "10 GB" — the storage caps as a reader would write them, from the
  # byte counts the quota engine actually applies.
  def gigabytes(bytes)
    "#{bytes / 1.gigabyte} GB"
  end

  # "60, 30 and 7" — a list of numbers in prose, without pulling a view helper
  # into a document that has to render identically outside a request.
  def sentence(values)
    values = values.map(&:to_s)

    return values.first.to_s if values.size <= 1

    "#{values[0..-2].join(', ')} and #{values[-1]}"
  end

  # "1 year" from the ActiveSupport durations the retention rules are written
  # in, so the prose cannot drift from the schedule.
  def duration_words(duration)
    duration.inspect
  end
end
