# frozen_string_literal: true

require 'tmpdir'

# The Terms of Service and the Privacy Policy: two public pages, and a record
# of who agreed to which version of them (Session 9 phase A, docs/legal.md).
#
# What this file protects:
#
#   * Both pages are readable by anybody, signed in or not, and are meant to
#     be found (no `noindex`).
#   * The `data-legal-sha256` a page advertises is the digest of exactly the
#     bytes it is showing, and the page shows exactly the bytes
#     LegalDocuments hashes. Those are what every acceptance row points at.
#   * Every number in the Terms comes from the constant the product applies.
#     A legal document is the one place in a codebase where a stale copy of a
#     number is not a bug report, it is a promise we did not mean to make.
#   * Neither document claims a compliance or a legal outcome. The list of
#     phrases below is the list a lawyer told us not to say, and the drafts go
#     to a review panel before launch.
#   * Every door that creates a login writes the agreement down, in the same
#     transaction as the person — so neither can exist without the other.
#   * A bump keeps the old text: an acceptance recorded against a superseded
#     version can still be resolved to the exact words behind it.
RSpec.describe 'Legal documents', type: :request do
  # Every phrase we have decided this product must never say about itself.
  # "Say what we do, not what a court would decide."
  let(:forbidden_claims) do
    ['ESIGN compliant', 'ESIGN-compliant', 'court-admissible', 'SOC 2', 'HIPAA', 'GDPR compliant']
  end
  let(:limits) { Quotas::Limits }

  # The instance is set up, so a public page is never the first-run redirect.
  before { create(:user, account: create(:account, :operator)) }

  def terms_html
    LegalDocuments.html(:terms)
  end

  def privacy_html
    LegalDocuments.html(:privacy)
  end

  # A sentence in the rendered document, with the source's own line wrapping
  # collapsed. Used for statements of FACT, where what matters is that the
  # document says the thing. The three quoted sentences below (D73, D74, D78)
  # are deliberately NOT read through this: those are exact wording, held to
  # the byte.
  def prose(html)
    html.gsub(/\s+/, ' ')
  end

  describe 'the pages' do
    it 'serves both to an anonymous visitor, with the version, the date and the exact hashed text' do
      LegalDocuments.documents.each do |document|
        get "/#{document}"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(LegalDocuments.version(document))
        expect(response.body).to include(LegalDocuments.effective_on(document).strftime('%-d %B %Y'))

        # The container advertises the digest, and holds the very bytes that
        # digest was taken over. A reader can check the two against each
        # other without a database, and an acceptance row points at both.
        expect(response.body).to include("data-legal-document=\"#{document}\"")

        # The attribute is the digest of the article's own inner HTML, byte
        # for byte — the check a reader can make for themselves, and the
        # thing an acceptance row points at.
        article = Nokogiri::HTML(response.body).at_css('article.legal-document')

        expect(article['data-legal-sha256']).to eq(LegalDocuments.sha256(document))
        expect(Digest::SHA256.hexdigest(article.inner_html)).to eq(article['data-legal-sha256'])
      end
    end

    it 'serves both to a signed-in user' do
      sign_in(create(:user, account: create(:account)))

      LegalDocuments.documents.each do |document|
        get "/#{document}"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("data-legal-sha256=\"#{LegalDocuments.sha256(document)}\"")
      end
    end

    it 'links each document to the other, to the Trust page and to the DocuSeal source' do
      get '/terms'

      expect(response.body).to include('href="/privacy"')
      expect(response.body).to include('href="/trust"')

      get '/privacy'

      expect(response.body).to include('href="/terms"')
      expect(response.body).to include('href="/trust"')

      # The AGPL attribution the marketing layout carries (rake gates:branding).
      expect(response.body).to include(Docuseal::DOCUSEAL_SOURCE_URL)
    end

    it 'lets search engines index them' do
      LegalDocuments.documents.each do |document|
        get "/#{document}"

        expect(response.body).not_to include('content="noindex"')
      end
    end
  end

  describe 'the Terms text' do
    it 'states the free plan in the numbers the quota engine applies' do
      expect(terms_html).to include("<td>#{limits::FREE_COMPLETIONS_PER_MONTH}</td>")
      expect(terms_html).to include("<td>#{limits::FREE_SENDS_PER_MONTH}</td>")
      expect(terms_html).to include("<td>#{limits::FREE_IN_FLIGHT}</td>")
      expect(terms_html).to include("<td>#{limits::FREE_SEATS}</td>")
      expect(terms_html).to include("<td>#{limits::FREE_STORAGE_BYTES / 1.gigabyte} GB</td>")
    end

    it 'states the paid plan in the numbers the billing code applies' do
      expect(terms_html).to include("$#{BillingSettingsController::PRICE_PER_SEAT_USD} per user per month")
      expect(terms_html).to include("#{StripeBilling::TRIAL_PERIOD_DAYS} days, free")
      expect(terms_html).to include("#{limits::PAID_STORAGE_BYTES_PER_SEAT / 1.gigabyte} GB per seat")
      expect(terms_html).to include("#{limits::PAID_COMPLETIONS_REVIEW_PER_SEAT} per seat per month")
      expect(terms_html).to include("#{limits::PAID_SENDS_PER_DAY_PER_SEAT} per seat per day")
      expect(terms_html).to include("#{limits::PAID_IN_FLIGHT_PER_SEAT} per seat")
      expect(terms_html).to include("#{BillingLifecycle::PAST_DUE_GRACE_DAYS} days of grace")
      expect(terms_html).to include("valid for #{BillingLifecycle::INVITE_TOKEN_DAYS} days")
    end

    # D73/D74. These two sentences are the answer to "can I fix a document
    # somebody already signed?", and they are quoted verbatim because the
    # answer people were given has to be the answer the code gives.
    it 'carries the correction rules word for word' do
      expect(terms_html).to include(
        'Correcting a signed document and sending it again never uses a second completion, ' \
        'however many rounds it takes; it still counts as a send.'
      )
      expect(terms_html).to include(
        'Correcting a signed document is allowed even when you have reached the monthly ' \
        'completion limit; it still counts as a send and as an open document.'
      )
    end

    # D78.
    it 'says what a legacy integration login may do' do
      expect(terms_html).to include(
        'A legacy integration login can only do document work through the API on its own account; ' \
        'it cannot manage users, seats or billing.'
      )
    end

    # Two brackets, and only two: the operator's legal name and its postal
    # address. A third would be something a lawyer had not been told about.
    it 'leaves only the marked brackets for the lawyer to fill in' do
      LegalDocuments.documents.each do |document|
        expect(LegalDocuments.html(document).scan(/\[[^\]]+\]/).uniq)
          .to match_array(LegalDocuments::LAWYER_PLACEHOLDERS)
      end
    end

    # Review 1 corrected each of these against the code that implements them.
    it 'describes an unpaid or paused subscription the way the billing code treats it' do
      # StripeBilling::SubscriptionSync maps `unpaid` and `paused` to
      # `suspended`, and BillingLifecycle suspends at once — it does NOT drop
      # the account to the free plan.
      expect(StripeBilling::SubscriptionSync::STATE_BY_STRIPE_STATUS.values_at('unpaid', 'paused'))
        .to eq(%w[suspended suspended])
      expect(prose(terms_html)).to include('suspended straight away')
      expect(prose(terms_html)).not_to include('drops to the free plan at once')
    end

    it 'says who is responsible when the API completes a document with no signer present' do
      expect(prose(terms_html)).to include('no consent is collected and none is recorded')
    end

    it 'qualifies what a permanent deletion leaves behind' do
      expect(prose(terms_html)).to include('kept permanently')
      expect(prose(terms_html)).to include('subscription and payment history')
      expect(prose(terms_html)).to include('log of support access')
      # operator_events is deliberately NOT in the purge inventory, so the
      # support-access log really does survive and the document says so.
      expect(Accounts::Purge::INVENTORY).not_to include('operator_events')
      expect(prose(terms_html)).not_to include('everything is permanently destroyed')
    end

    it 'says the free month ends with the calendar month' do
      expect(prose(terms_html)).to include('That free month still ends with the calendar month, not thirty days later.')
    end

    it 'names the paid-only features and links the full list' do
      %w[webhooks reminders conditional].each { |word| expect(terms_html).to include(word) }
      expect(terms_html).to include('href="/pricing"')
    end

    it 'uses US spelling' do
      %w[organisation honouring cancelling cancelled licence behaviour authorised enrolment].each do |word|
        expect(terms_html).not_to include(word)
        expect(privacy_html).not_to include(word)
      end
    end
  end

  describe 'the Privacy text' do
    it 'says opens and clicks are recorded on every plan and only shown on some' do
      # lib/postmark_webhooks.rb records the geo fields for every account;
      # lib/submission_events.rb filters the tracking types on READ.
      expect(SubmissionEvents::TRACKING_TYPES).to include('open_email', 'click_email')
      expect(prose(privacy_html)).to include('every</em> plan')
      expect(prose(privacy_html)).to include('includes delivery tracking')
    end

    it 'lists the cookies a signer gets, not only an account holder s' do
      ['12 hours', 'signature you saved', 'emailed verification code'].each do |phrase|
        expect(prose(privacy_html)).to include(phrase)
      end
    end

    it 'describes support access the way the code actually works' do
      expect(prose(privacy_html)).to include('authenticator app')
      expect(prose(privacy_html)).to include('Support access')
      expect(prose(privacy_html)).to include("our operator's own screens carry a banner")
    end

    it 'does not claim nobody outside the team can reach customer data' do
      expect(prose(privacy_html)).not_to include('nobody outside it can reach')
      expect(prose(privacy_html)).to include('under their own terms')
    end

    # A3 (independent review). The tracking EVENTS really are off-plan, but one
    # fact drawn from them is not: `click_email_event` alone prints "Email
    # verification: Verified" in the per-signer facts block of every audit
    # trail, on every plan (lib/submissions/generate_audit_trail.rb). The
    # document used to deny that in as many words.
    it 'admits the audit trail records that the address was verified, on every plan' do
      expect(prose(privacy_html)).to include('records that your email address was verified, on every plan')
      expect(prose(privacy_html))
        .not_to include("not shown to them, in the document's event list, in the audit trail")
    end

    # S9-05 (independent review). Devise trackable keeps two sign-in IP
    # addresses and no user agent at all; nothing anywhere records a password
    # change or a two-factor enrollment. The agreements in this spec's own
    # `legal_acceptances` rows are the only place both are kept, so those are
    # the only places the document may claim them.
    it 'claims only the sign-in and agreement records the schema actually holds' do
      expect(User.column_names).to include('current_sign_in_ip', 'last_sign_in_ip')
      expect(User.column_names).not_to include('user_agent')
      expect(LegalAcceptance.column_names).to include('ip', 'user_agent')

      expect(prose(privacy_html)).to include('we do not record which browser you signed in with')
      expect(prose(privacy_html)).to include('creates no record of its own')
      expect(prose(privacy_html)).to include('the IP address and browser user agent your browser sent with it')
      expect(prose(privacy_html)).not_to include('password change, two-factor enrollment')
    end

    it 'describes the archive, permanent verification records and provider backups honestly' do
      expect(prose(privacy_html)).to include('Delete permanently')
      expect(prose(privacy_html)).to include('Verification records are kept permanently.')
      expect(prose(privacy_html)).to include('automatic database backups')
      expect(prose(privacy_html)).to include("Amazon's server-side encryption")
      expect(prose(privacy_html)).to include('without undue delay')
      expect(prose(privacy_html)).to include('Postmark (an ActiveCampaign company)')
    end
  end

  describe 'what neither document may claim' do
    it 'never claims a compliance or a legal outcome' do
      forbidden_claims.each do |claim|
        expect(terms_html).not_to include(claim)
        expect(privacy_html).not_to include(claim)
      end
    end
  end

  describe 'the digest and the archive' do
    it 'digests exactly the text it publishes' do
      LegalDocuments.documents.each do |document|
        expect(LegalDocuments.sha256(document))
          .to eq(Digest::SHA256.hexdigest(LegalDocuments.html(document)))
      end
    end

    # A1 (independent review). Every other check in this file compares the
    # render to itself and so cannot notice a wording edit. This one compares
    # it to a digest written down by hand beside the version, which means any
    # edit at all — a corrected typo included — goes red until its author has
    # followed the bump procedure in docs/legal.md: archive the old text, bump
    # the version and the effective date, record the new digest. It is the one
    # guard that makes a stored (version, sha256) pair mean anything.
    it 'renders each document at exactly the digest pinned beside its version' do
      LegalDocuments.documents.each do |document|
        expect(LegalDocuments.sha256(document)).to eq(LegalDocuments::DOCUMENTS[document][:sha256])
      end
    end

    # The real config/legal/archive, not a tmpdir: every superseded text we
    # actually ship still reads back at the digest recorded on the day it was
    # published, so an acceptance row naming that version resolves to the
    # exact words behind it.
    it 'reads every text in the real archive back at its recorded digest' do
      archived = LegalDocuments::ARCHIVE_DIR.glob('*.html')

      expect(archived).not_to be_empty

      archived.each do |path|
        document, version = path.basename('.html').to_s.split('-', 2)
        recorded = LegalDocuments::DOCUMENTS.dig(document.to_sym, :archived, version)

        expect(LegalDocuments.documents.map(&:to_s)).to include(document)
        expect(recorded).to be_present
        expect(LegalDocuments.html(document, version:)).to eq(path.read)
        expect(LegalDocuments.sha256(document, version:)).to eq(recorded)
        expect(version).not_to eq(LegalDocuments.version(document))
      end
    end

    it 'refuses an archived text that no longer hashes to its recorded digest' do
      Dir.mktmpdir do |archive|
        File.write(File.join(archive, 'terms-2026-01-01.html'), "#{terms_html}<!-- edited -->")

        stub_const('LegalDocuments::ARCHIVE_DIR', Pathname.new(archive))
        stub_const('LegalDocuments::DOCUMENTS',
                   LegalDocuments::DOCUMENTS.merge(
                     terms: LegalDocuments::DOCUMENTS[:terms].merge(
                       archived: { '2026-01-01' => Digest::SHA256.hexdigest(terms_html) }
                     )
                   ))

        expect { LegalDocuments.html(:terms, version: '2026-01-01') }
          .to raise_error(LegalDocuments::ArchiveMismatchError)
      end
    end

    it 'answers nil for a document it does not publish and for a version nobody ever saw' do
      expect(LegalDocuments.html(:cookies)).to be_nil
      expect(LegalDocuments.sha256(:cookies)).to be_nil
      expect(LegalDocuments.html(:terms, version: '1999-01-01')).to be_nil
      expect(LegalDocuments.html(:terms, version: '../../../etc/passwd')).to be_nil
    end

    # The whole point of the version rule: an acceptance recorded today has to
    # still resolve to today's words after the document is rewritten.
    it 'reads a superseded version back out of the archive, digest and all' do
      old_version = LegalDocuments.version(:terms)
      old_html = terms_html
      old_sha = LegalDocuments.sha256(:terms)

      Dir.mktmpdir do |archive|
        File.write(File.join(archive, "terms-#{old_version}.html"), old_html)

        stub_const('LegalDocuments::ARCHIVE_DIR', Pathname.new(archive))
        stub_const('LegalDocuments::DOCUMENTS',
                   LegalDocuments::DOCUMENTS.merge(
                     terms: { version: '2027-03-01', effective_on: Date.new(2027, 3, 1),
                              sha256: LegalDocuments::DOCUMENTS[:terms][:sha256],
                              archived: { old_version => old_sha } }
                   ))

        expect(LegalDocuments.version(:terms)).to eq('2027-03-01')
        expect(LegalDocuments.html(:terms, version: old_version)).to eq(old_html)
        expect(LegalDocuments.sha256(:terms, version: old_version)).to eq(old_sha)
        expect(LegalDocuments.html(:terms, version: '2026-01-01')).to be_nil
      end
    end
  end

  describe 'recording the agreement' do
    stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'TURNSTILE_SECRET_KEY',
              'GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET',
              'APPLE_OAUTH_CLIENT_ID', 'APPLE_OAUTH_TEAM_ID', 'APPLE_OAUTH_KEY_ID',
              'APPLE_OAUTH_PRIVATE_KEY', clear: true

    before { RateLimit.store.clear }

    after do
      RateLimit.store.clear
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:google_oauth2] = nil
      OmniAuth.config.mock_auth[:apple] = nil
    end

    def enable_registration!
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
      ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
    end

    def sign_up(email: 'ada@example.com', versions: LegalDocuments.version_fields)
      post registration_path, params: { user: { name: 'Ada Lovelace', email:, password: 'a-long-password',
                                                timezone: 'Europe/Paris' },
                                        'cf-turnstile-response' => 'turnstile-token', **versions },
                              headers: { 'HTTP_USER_AGENT' => 'RSpec Browser 1.0' }
    end

    def mock_google(email:)
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] =
        OmniAuth::AuthHash.new(provider: 'google_oauth2', uid: '107691503500061507151',
                               info: { email:, name: 'Grace Hopper' },
                               extra: { raw_info: { email_verified: true } })
    end

    def enable_apple!
      ENV['APPLE_OAUTH_CLIENT_ID'] = 'com.esigncenter.web'
      ENV['APPLE_OAUTH_TEAM_ID'] = 'AB1234CD56'
      ENV['APPLE_OAUTH_KEY_ID'] = 'EF7890GH12'
      ENV['APPLE_OAUTH_PRIVATE_KEY'] = OpenSSL::PKey::EC.generate('prime256v1').to_pem
    end

    def mock_apple(email:)
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:apple] =
        OmniAuth::AuthHash.new(provider: 'apple', uid: '001234.fedcba9876543210.1234',
                               info: { email:, name: 'Grace Hopper', email_verified: true })
    end

    # The button puts the displayed versions on the authorize query string, so
    # the real flow hands them to the callback as `omniauth.params`.
    def sign_in_with_google!(versions: LegalDocuments.version_fields)
      post user_google_oauth2_omniauth_authorize_path(versions)

      follow_redirect!
    end

    # The same, with Apple's cross-site form POST in place of the redirect.
    def sign_in_with_apple!(versions: LegalDocuments.version_fields)
      post user_apple_omniauth_authorize_path(versions)

      post user_apple_omniauth_callback_path
    end

    # Both documents, at their current version, with the digest of the exact
    # text that was published on the day.
    def expect_current_pair(rows, source:, account:)
      expect(rows.map(&:document)).to match_array(%w[privacy terms])
      expect(rows.map(&:source).uniq).to eq([source])
      expect(rows.map(&:account_id).uniq).to eq([account.id])

      rows.each do |row|
        expect(row.version).to eq(LegalDocuments.version(row.document))
        expect(row.sha256).to eq(LegalDocuments.sha256(row.document))
        expect(row.accepted_at).to be_present
      end
    end

    it 'writes both documents when somebody signs up with an email address' do
      enable_registration!
      stub_turnstile(success: true)

      expect { sign_up }.to change(LegalAcceptance, :count).by(2)

      user = User.find_by!(email: 'ada@example.com')
      rows = LegalAcceptance.where(user:).to_a

      expect_current_pair(rows, source: LegalAcceptance::SIGNUP_EMAIL, account: user.account)
      expect(rows.map(&:ip).uniq).to eq(['127.0.0.1'])
      expect(rows.map(&:user_agent).uniq).to eq(['RSpec Browser 1.0'])
    end

    it 'writes both documents when somebody signs up with Google' do
      enable_registration!
      ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
      ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'
      mock_google(email: 'grace@example.com')

      expect { sign_in_with_google! }.to change(LegalAcceptance, :count).by(2)

      user = User.find_by!(email: 'grace@example.com')

      expect_current_pair(LegalAcceptance.where(user:).to_a,
                          source: LegalAcceptance::SIGNUP_GOOGLE, account: user.account)
    end

    it 'writes both documents when somebody signs up with Apple' do
      enable_registration!
      enable_apple!
      mock_apple(email: 'grace-apple@example.com')

      expect { sign_in_with_apple! }.to change(LegalAcceptance, :count).by(2)

      user = User.find_by!(email: 'grace-apple@example.com')

      expect_current_pair(LegalAcceptance.where(user:).to_a,
                          source: LegalAcceptance::SIGNUP_APPLE, account: user.account)
    end

    # The Apple button carries the versions it displayed on the authorize
    # query string exactly as the Google one does, so a button drawn before a
    # wording change records nothing.
    it 'refuses an Apple sign-up whose button was showing a superseded version' do
      enable_registration!
      enable_apple!
      mock_apple(email: 'stale-apple@example.com')
      stale = LegalDocuments.version_fields.transform_values { '2020-01-01' }

      expect { sign_in_with_apple!(versions: stale) }.not_to change(LegalAcceptance, :count)

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('legal_documents_updated_please_review'))
      expect(User.find_by(email: 'stale-apple@example.com')).to be_nil
    end

    it 'writes both documents against the INVITING account when a new person accepts an invitation' do
      account = create(:account)
      create(:user, account:)
      create(:account_subscription, account:, seats: 2)
      invite = create(:account_invite, account:, role: User::EDITOR_ROLE)

      expect do
        post "/invites/#{invite.raw_token}",
             params: { first_name: 'Sam', last_name: 'Rivers', password: 'password-123',
                       **LegalDocuments.version_fields }
      end.to change(LegalAcceptance, :count).by(2)

      user = User.find_by!(email: invite.email)

      expect_current_pair(LegalAcceptance.where(user:).to_a, source: LegalAcceptance::INVITE, account:)
    end

    it 'writes nothing when the sign-up is refused' do
      enable_registration!
      stub_turnstile(success: true)

      expect { sign_up(email: 'ada@mailinator.com') }.not_to change(LegalAcceptance, :count)
      expect(User.find_by(email: 'ada@mailinator.com')).to be_nil
    end

    # The transaction, from the other end: if the agreement cannot be written
    # there is no sign-up either. A login that never agreed to anything is
    # worse than a sign-up that failed.
    it 'leaves no user behind when the agreement cannot be recorded' do
      enable_registration!
      stub_turnstile(success: true)

      allow(LegalDocuments).to receive(:record_acceptance!).and_raise(ActiveRecord::RecordNotSaved)

      expect { sign_up }.to raise_error(ActiveRecord::RecordNotSaved)

      # The writer really was reached — the sign-up got as far as having a
      # user to record an agreement for, and the transaction took it back.
      expect(LegalDocuments).to have_received(:record_acceptance!)
      expect(User.find_by(email: 'ada@example.com')).to be_nil
      expect(LegalAcceptance.count).to eq(0)
    end

    it 'knows whether somebody has agreed to the current version of everything' do
      enable_registration!
      stub_turnstile(success: true)
      sign_up

      user = User.find_by!(email: 'ada@example.com')

      expect(LegalDocuments.accepted_current?(user)).to be(true)

      LegalAcceptance.where(user:, document: 'privacy').update_all(version: '2020-01-01')

      expect(LegalDocuments.accepted_current?(user)).to be(false)
    end
  end

  # Codex review 1: an acceptance must name the text the person actually read.
  # A page opened before a wording change sends back the version it displayed,
  # and every door refuses rather than recording an agreement to words nobody
  # ever saw — the rule EsignConsent applies to a signer's disclosure.
  describe 'a page that was open across a wording change' do
    stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY', 'TURNSTILE_SECRET_KEY',
              'GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET', clear: true

    let(:stale) { LegalDocuments.version_fields.transform_values { |_| '2020-01-01' } }

    before do
      RateLimit.store.clear
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
      ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
    end

    after do
      RateLimit.store.clear
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:google_oauth2] = nil
    end

    def sign_up(versions:)
      post registration_path, params: { user: { name: 'Ada Lovelace', email: 'ada@example.com',
                                                password: 'a-long-password', timezone: 'Europe/Paris' },
                                        'cf-turnstile-response' => 'turnstile-token', **versions }
    end

    it 'refuses an email sign-up carrying a superseded version, and creates nothing' do
      stub_turnstile(success: true)

      expect { sign_up(versions: stale) }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('legal_documents_updated_please_review'))
      expect(LegalAcceptance.count).to eq(0)
    end

    it 'refuses an email sign-up that sends no versions at all' do
      stub_turnstile(success: true)

      expect { sign_up(versions: {}) }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(LegalAcceptance.count).to eq(0)
    end

    it 'refuses a Google sign-up carrying a superseded version, and creates nothing' do
      ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
      ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] =
        OmniAuth::AuthHash.new(provider: 'google_oauth2', uid: '107691503500061507151',
                               info: { email: 'grace@example.com', name: 'Grace Hopper' },
                               extra: { raw_info: { email_verified: true } })

      expect do
        post user_google_oauth2_omniauth_authorize_path(stale)
        follow_redirect!
      end.not_to change(User, :count)

      expect(flash[:alert]).to eq(I18n.t('legal_documents_updated_please_review'))
      expect(LegalAcceptance.count).to eq(0)
    end

    it 'refuses a Google sign-up that carries no versions at all' do
      ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
      ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] =
        OmniAuth::AuthHash.new(provider: 'google_oauth2', uid: '107691503500061507152',
                               info: { email: 'ada@example.com', name: 'Ada Lovelace' },
                               extra: { raw_info: { email_verified: true } })

      expect do
        post user_google_oauth2_omniauth_authorize_path
        follow_redirect!
      end.not_to change(User, :count)

      expect(flash[:alert]).to eq(I18n.t('legal_documents_updated_please_review'))
      expect(LegalAcceptance.count).to eq(0)
    end

    # The Google door's half of the transaction proof: the user really is
    # saved before the agreement is written, so the rollback is the only thing
    # standing between us and a Google login that agreed to nothing.
    it 'leaves no user behind when the agreement cannot be recorded on the Google door' do
      ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
      ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] =
        OmniAuth::AuthHash.new(provider: 'google_oauth2', uid: '107691503500061507153',
                               info: { email: 'grace@example.com', name: 'Grace Hopper' },
                               extra: { raw_info: { email_verified: true } })

      allow(LegalDocuments).to receive(:record_acceptance!).and_raise(ActiveRecord::RecordNotSaved)

      expect do
        post user_google_oauth2_omniauth_authorize_path(LegalDocuments.version_fields)
        expect { follow_redirect! }.to raise_error(ActiveRecord::RecordNotSaved)
      end.not_to change(User, :count)

      expect(LegalDocuments).to have_received(:record_acceptance!)
      expect(User.find_by(email: 'grace@example.com')).to be_nil
      expect(Account.where(name: 'Grace Hopper')).to be_empty
      expect(LegalAcceptance.count).to eq(0)
    end

    it 'refuses an invitation accepted on a stale page, and creates nothing' do
      account = create(:account)
      create(:user, account:)
      create(:account_subscription, account:, seats: 2)
      invite = create(:account_invite, account:, role: User::EDITOR_ROLE)

      expect do
        post "/invites/#{invite.raw_token}",
             params: { first_name: 'Sam', last_name: 'Rivers', password: 'password-123', **stale }
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('legal_documents_updated_please_review'))
      expect(LegalAcceptance.count).to eq(0)
      expect(invite.reload.accepted_at).to be_nil
    end

    it 'refuses at the writer too, whatever a caller forgot to ask' do
      user = create(:user, account: create(:account))

      expect do
        LegalDocuments.record_acceptance!(user, request: nil, source: LegalAcceptance::INVITE, versions: nil)
      end.to raise_error(LegalDocuments::StaleVersionError)

      expect(LegalAcceptance.count).to eq(0)
    end
  end

  # Review 1: an agreement belongs to the PERSON, so it follows them out of an
  # account they leave — and the account they left has to be able to die.
  describe 'somebody who joins another team' do
    it 'records nothing new, takes their agreement with them, and frees the old account to be purged' do
      old_account = create(:account)
      mover = create(:user, account: old_account)
      LegalDocuments.record_acceptance!(mover, request: nil, source: LegalAcceptance::SIGNUP_EMAIL,
                                               versions: LegalDocuments.current_versions)

      team = create(:account)
      create(:user, account: team)
      create(:account_subscription, account: team, seats: 2)
      invite = create(:account_invite, account: team, email: mover.email, role: User::EDITOR_ROLE)

      # A move is not a sign-up: this person already agreed when they made
      # their login, and moving house does not change what they agreed to.
      expect { AccountInvites.accept_move!(invite, user: mover) }.not_to change(LegalAcceptance, :count)

      expect(LegalAcceptance.where(user: mover).pluck(:account_id).uniq).to eq([team.id])

      # The old account now has no users at all. Its purge used to walk past
      # the rows it still owned and then refuse forever.
      old_account.reload.update!(deletion_requested_at: 90.days.ago, purge_scheduled_for: 1.minute.ago,
                                 archived_at: nil)

      expect(Accounts::Purge.call(old_account)).to eq(:purged)
      expect(LegalAcceptance.where(user: mover).count).to eq(2)
    end
  end

  describe 'the agreement sentence' do
    # These examples switch sign-up and the Google button on. They used to put
    # the variables back by DELETING them, which is not the same as putting
    # them back: the test container runs with REGISTRATION_ENABLED=true, so
    # every later example in the same process saw sign-up switched off and
    # /sign_up answering 404 (it reddened spec/golden/support_spec.rb's
    # turbo-visit-control example in the full suite, never on its own).
    # `stash_env` restores the value that was there.
    stash_env 'REGISTRATION_ENABLED', 'TURNSTILE_SITE_KEY',
              'GOOGLE_OAUTH_CLIENT_ID', 'GOOGLE_OAUTH_CLIENT_SECRET'

    it 'is on the sign-up form, with both links' do
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'

      get new_registration_path

      expect(response.body).to include('href="/terms"')
      expect(response.body).to include('href="/privacy"')
    end

    # The sign-in page's Google button creates an account for an address that
    # has never signed up, so it is a sign-up door and needs the sentence too
    # (review 1).
    it 'is on the sign-in page whenever the Google button can create an account' do
      ENV['REGISTRATION_ENABLED'] = 'true'
      ENV['GOOGLE_OAUTH_CLIENT_ID'] = 'google-client-id'
      ENV['GOOGLE_OAUTH_CLIENT_SECRET'] = 'google-client-secret'

      get new_user_session_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('continue_with_google'))
      expect(response.body).to include('href="/terms"')
      expect(response.body).to include('href="/privacy"')
      # And the button carries the versions it is displaying.
      LegalDocuments.version_fields.each { |field, value| expect(response.body).to include("#{field}=#{value}") }
    end

    it 'is on the invitation form, with both links' do
      account = create(:account)
      create(:user, account:)
      create(:account_subscription, account:, seats: 2)
      invite = create(:account_invite, account:, role: User::EDITOR_ROLE)

      get "/invites/#{invite.raw_token}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('href="/terms"')
      expect(response.body).to include('href="/privacy"')
    end
  end
end
