# frozen_string_literal: true

# A human signer cannot complete without recorded ESIGN consent on any path;
# sender-attested API completions are the documented exemption.
#
# Every interactive path (emailed link, share link, embedded signing session,
# resubmit, email-2FA, invite-then-complete, selfsign) ends in
# Submitters::SubmitValues. Completing there without an `esign_consent` event
# is refused with a JSON 422 and leaves nothing behind: no completed_at, no
# completion job, no complete_form event. With `esign_consent=true` and the
# current `esign_consent_version` the completion succeeds and exactly one
# versioned consent event carrying the signer's IP exists, stamped with the
# locale the disclosure was shown in and the SHA-256 of that disclosure text
# (computed on the server, never taken from the client). The consent line —
# version and locale — is printed in the audit trail in every base locale,
# and no locale can show a missing translation.
#
# Sender-attested completions (API `completed: true`, signing sessions created
# completed) have no human signer: they complete with zero consent events and
# an `api_complete_form` event instead. See docs/esign-consent.md.

module ConsentSpecSupport
  BASE_LOCALES = %w[en es it fr pt de pl uk cs he nl ar ko ja].freeze
  CONSENT_KEYS = %w[esign_consent_checkbox_label esign_consent_disclosure_link esign_consent_disclosure_title
                    esign_consent_disclosure_body_html esign_consent_version_label esign_consent_required
                    esign_consent_version_stale consented_to_electronic_signatures close
                    submission_event_names.esign_consent_by_html].freeze
end

# Collects the strings a PDF's content streams actually draw, decoded through
# each embedded font's ToUnicode map — the text a reader would copy from the
# page, so a missing glyph or a bad font map would break the assertion.
class ConsentSpecTextCollector < HexaPDF::Content::Processor
  attr_reader :text

  def initialize(resources = nil)
    super
    @text = +''
  end

  def show_text(str)
    @text << decode_text(str)
  end

  def show_text_with_positioning(array)
    @text << decode_text(array)
  end
end

RSpec.describe 'ESIGN consent', type: :request do
  let!(:account) { create(:account) }
  let!(:paid_account) { create(:account, :paid) }
  let!(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }
  let(:json_headers) { { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' } }

  def admin_for(account)
    admins[account.id] ||= create(:user, account:)
  end

  def token_headers(account)
    { 'x-auth-token': admin_for(account).access_token.token }
  end

  # A fresh integration session, then that account's admin (see gating_spec).
  def act_as(account)
    sign_out(:user)
    reset!
    sign_in(admin_for(account))
  end

  def text_template_for(account, **attrs)
    create(:template, account:, author: admin_for(account), only_field_types: %w[text], **attrs)
  end

  def emailed_submitter_for(account, template: text_template_for(account))
    submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))
    submission.submitters.first.tap { |s| s.update!(sent_at: Time.current, email: 'signer@example.com') }
  end

  # The consent always travels with the version the form displayed
  # (consent_version_spec proves a missing or stale version is refused) and
  # the locale it was displayed in.
  def consent_params(locale: 'en')
    { esign_consent: 'true', esign_consent_version: EsignConsent::VERSION, esign_consent_locale: locale }
  end

  def completion_params(submitter, esign_consent: nil)
    params = { completed: 'true', values: { text_field(submitter)['uuid'] => 'Jane' } }

    esign_consent ? params.merge(consent_params) : params
  end

  def create_signing_session(account, headers, submitter_attrs = {})
    template = text_template_for(account)

    post '/api/signing_sessions', headers: headers.merge(json_headers), params: {
      template_id: template.id,
      embed_origin: 'https://app.example.com',
      submitters: [{ role: template.submitters.first['name'], email: 'signer@example.com', **submitter_attrs }]
    }.to_json
  end

  def consent_events(submitter)
    submitter.submission_events.where(event_type: 'esign_consent')
  end

  def expect_consent_refused(submitter)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq('error' => 'esign_consent_required')
    expect(submitter.reload.completed_at).to be_nil
    expect(ProcessSubmitterCompletionJob.jobs).to be_empty
    expect(submitter.submission_events.where(event_type: %w[complete_form esign_consent])).not_to exist
  end

  def expect_completed_with_consent(submitter, locale: 'en')
    expect(response).to have_http_status(:ok)
    expect(submitter.reload.completed_at).to be_present
    expect(submitter.submission_events.where(event_type: 'complete_form').count).to eq(1)
    expect(consent_events(submitter).count).to eq(1)
    expect_consent_data(consent_events(submitter).sole.data, locale:)
  end

  # The event names the exact text the signer agreed to: version, locale and
  # the digest of the disclosure body in that locale, which must be the one
  # EsignConsent recomputes from the locale data (a later verifier's check).
  def expect_consent_data(data, locale:)
    expect(data).to include('version' => 'v1', 'locale' => locale)
    expect(data['disclosure_sha256']).to match(/\A\h{64}\z/)
    expect(data['disclosure_sha256']).to eq(EsignConsent.disclosure_sha256(version: 'v1', locale:))
    expect(data['ip']).to be_present
  end

  def expect_gated(submitter)
    put "/s/#{submitter.slug}", params: completion_params(submitter)
    expect_consent_refused(submitter)

    put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
    expect_completed_with_consent(submitter)
    expect(ProcessSubmitterCompletionJob.jobs.size).to eq(1)
  end

  # The consent contract the signing page hands the form (the partial's
  # data-esign-consent attribute): `consented: true` hides the checkbox.
  def esign_consent_contract
    JSON.parse(Nokogiri::HTML(response.body).at_css('submission-form')['data-esign-consent'])
  end

  def pdf_text(bytes)
    document = HexaPDF::Document.new(io: StringIO.new(bytes))

    document.pages.map do |page|
      collector = ConsentSpecTextCollector.new(page.resources)
      page.process_contents(collector)
      collector.text
    end.join(' ')
  end

  # A phrase as it may come back out of the PDF: line wraps fall between
  # words and the collector keeps no whitespace across them.
  def pdf_phrase(text)
    Regexp.new(text.split(/\s+/).map { |word| Regexp.escape(word) }.join('\s*'))
  end

  # The per-signer audit line for a consent given at `time`
  # ("Consented to electronic signatures (v1, en): September 01, 2026 10:00").
  def consent_line(time, locale: 'en')
    pdf_phrase("#{I18n.t('consented_to_electronic_signatures')} (#{EsignConsent::VERSION}, #{locale}): " \
               "#{I18n.l(time.in_time_zone(account.timezone), format: :long, locale: account.locale)}")
  end

  describe 'interactive paths' do
    it 'gates an emailed submitter (PUT /s/:slug)' do
      expect_gated(emailed_submitter_for(account))
    end

    it 'gates a share-link signer (PUT /d/:slug creates the submitter, then /s/:slug)' do
      template = text_template_for(account, shared_link: true)

      put "/d/#{template.slug}", params: { submitter: { email: 'signer@example.com' } }

      submitter = Submitter.last

      expect(response).to redirect_to("/s/#{submitter.slug}")
      expect(submitter.submission.source).to eq('link')

      expect_gated(submitter)
    end

    it 'gates an embedded signing-session signer and returns the embed completion payload' do
      create_signing_session(paid_account, token_headers(paid_account))

      expect(response).to have_http_status(:ok)

      submitter = Submission.last.submitters.first

      # The embed mount carries the consent contract too.
      get "/s/#{submitter.slug}"
      expect(response.body).to include('data-esign-consent=')
      expect(response.body).to include('id="esign_disclosure_modal"')

      expect_gated(submitter)

      expect(response.parsed_body.dig('submitter', 'status')).to eq('completed')
      expect(response.parsed_body.dig('signing_session', 'status')).to eq('completed')
    end

    it 'gates a resubmitted signer afresh: consent never carries over from the original submitter' do
      original = emailed_submitter_for(account)

      put "/s/#{original.slug}", params: completion_params(original, esign_consent: 'true')
      expect_completed_with_consent(original)

      put '/resubmit_form', params: { resubmit: original.slug }

      fresh = Submitter.last

      expect(fresh).not_to eq(original)
      expect(response).to redirect_to("/s/#{fresh.slug}")
      expect(EsignConsent.consented?(fresh)).to be(false)

      Sidekiq::Worker.clear_all

      expect_gated(fresh)
    end

    it 'gates the dashboard resubmit (PUT /submitters_resubmit/:id) afresh' do
      original = emailed_submitter_for(account)
      # The dashboard offers "resubmit" only for the signed-in user's own row.
      original.update!(email: admin_for(account).email)

      put "/s/#{original.slug}", params: completion_params(original, esign_consent: 'true')
      expect_completed_with_consent(original)

      act_as(account)
      put "/submitters_resubmit/#{original.id}"

      fresh = Submitter.last

      expect(fresh).not_to eq(original)
      expect(response).to redirect_to("/s/#{fresh.slug}")
      expect(EsignConsent.consented?(fresh)).to be(false)

      Sidekiq::Worker.clear_all

      expect_gated(fresh)
    end

    it 'gates "Sign in person" (the /s/:slug link on the submission page)' do
      submitter = emailed_submitter_for(account)

      act_as(account)
      get "/submissions/#{submitter.submission_id}"

      expect(response).to have_http_status(:ok)

      link = Nokogiri::HTML(response.body).css('a').find { |a| a.text.strip == I18n.t('sign_in_person') }

      expect(link).to be_present
      expect(link['href']).to eq("/s/#{submitter.slug}")

      expect_gated(submitter)
    end

    it 'gates an email-2FA signer after the code is verified' do
      template = text_template_for(account)
      template.update!(preferences: { 'require_email_2fa' => true })
      submitter = emailed_submitter_for(account, template:)

      # Before verification the 2FA gate answers, not the consent gate.
      put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq(I18n.t('verification_required_refresh_the_page_and_pass_2fa'))
      expect(consent_events(submitter)).not_to exist

      # The code the verification email carries, verified through the real
      # endpoint (it sets the 2FA cookie this session keeps).
      code = EmailVerificationCodes.generate([submitter.email.downcase.strip, submitter.slug].join(':'))
      post '/submit_form_email_2fa', params: { submitter_slug: submitter.slug, one_time_code: code }

      expect(response).to redirect_to("/s/#{submitter.slug}")
      expect(submitter.submission_events.where(event_type: 'email_verified')).to exist

      expect_gated(submitter)
    end

    it 'gates invite-then-complete, with consent travelling on the invite request' do
      template = create(:template, account:, author: admin_for(account), submitter_count: 2, only_field_types: %w[text])
      first, second = template.submitters
      second['invite_by_uuid'] = first['uuid']
      template.save!

      submission = create(:submission, template:, created_by_user: admin_for(account))
      submitter = create(:submitter, submission:, account:, uuid: first['uuid'], email: 'first@example.com',
                                     sent_at: Time.current)
      invite = { submission: { submitters: [{ uuid: second['uuid'], email: 'second@example.com' }] } }

      # The step save carries no consent; the invite request then completes.
      put "/s/#{submitter.slug}", params: { values: { text_field(submitter)['uuid'] => 'Jane' } }
      expect(response).to have_http_status(:ok)

      post "/s/#{submitter.slug}/invite", params: invite
      expect_consent_refused(submitter)

      post "/s/#{submitter.slug}/invite", params: invite.merge(consent_params)
      expect_completed_with_consent(submitter)
      expect(submission.submitters.where(uuid: second['uuid']).count).to eq(1)
    end

    it 'gates the sender signing their own template (selfsign via the start form)' do
      template = text_template_for(account)

      act_as(account)
      put "/d/#{template.slug}", params: { selfsign: true }

      submitter = Submitter.last

      expect(response).to redirect_to("/s/#{submitter.slug}")
      expect(submitter.email).to eq(admin_for(account).email)

      expect_gated(submitter)
    end

    it 'gates an internal account signer too (D53)' do
      expect_gated(emailed_submitter_for(internal_account))
    end
  end

  # Delegation keeps the submitter row (new email, new slug) — the consent
  # the first person gave must not let the second one finish.
  describe 'delegation', sidekiq: :inline do
    it 'asks the person a form was delegated to for their own consent, then prints it in their audit block' do
      platform_certificate!
      create(:account_config, account:, key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)
      submitter = emailed_submitter_for(account)
      old_slug = submitter.slug

      # A consents at T, B an hour later: the audit block must show B's time.
      a_consented_at = Time.zone.parse('2026-09-01 10:00:00 UTC')
      b_consented_at = a_consented_at + 1.hour

      # A agrees on a step save without completing.
      travel_to(a_consented_at) do
        put "/s/#{old_slug}", params: { values: { text_field(submitter)['uuid'] => 'Jane' }, **consent_params }
      end
      expect(response).to have_http_status(:ok)
      first_consent = consent_events(submitter).sole
      expect(EsignConsent.consented?(submitter)).to be(true)

      # A hands the form to B: same row, new email and slug, one delegate_form event.
      travel_to(a_consented_at + 30.minutes) do
        post "/s/#{old_slug}/delegate", params: { email: 'b@example.com' }
      end
      expect(response).to redirect_to("/s/#{old_slug}/delegated")

      submitter.reload
      expect(submitter.email).to eq('b@example.com')
      expect(submitter.slug).not_to eq(old_slug)
      delegate_event = submitter.submission_events.where(event_type: 'delegate_form').sole
      expect(delegate_event.event_timestamp).to be > first_consent.event_timestamp
      expect(EsignConsent.consented?(submitter)).to be(false)

      # B opens the form: the checkbox is back.
      get "/s/#{submitter.slug}"
      expect(response).to have_http_status(:ok)
      expect(esign_consent_contract).to include('consented' => false, 'version' => EsignConsent::VERSION,
                                                'locale' => 'en')

      # B cannot complete on A's consent.
      put "/s/#{submitter.slug}", params: completion_params(submitter)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_required')
      expect(submitter.reload.completed_at).to be_nil
      expect(submitter.submission_events.where(event_type: 'complete_form')).not_to exist
      expect(consent_events(submitter).count).to eq(1)

      # B agrees on a step save without completing: a second, newer event
      # carrying B's own tracking data; A's stays in the log.
      travel_to(b_consented_at) do
        put "/s/#{submitter.slug}", params: { values: { text_field(submitter)['uuid'] => 'Jane' }, **consent_params }
      end
      expect(response).to have_http_status(:ok)
      expect(submitter.reload.completed_at).to be_nil

      consents = consent_events(submitter).order(:id).to_a
      expect(consents).to match([
                                  have_attributes(id: first_consent.id, event_timestamp: a_consented_at),
                                  have_attributes(event_timestamp: b_consented_at,
                                                  data: include('version' => EsignConsent::VERSION,
                                                                'locale' => 'en',
                                                                'ip' => be_present))
                                ])

      # B completes, sending the consent again: record! finds B's event (not
      # A's) and creates no third one — the post-delegation idempotency proof.
      # (A PUT after completion would prove nothing: the controller answers
      # 422 form_has_been_completed_already before consent is consulted.)
      travel_to(b_consented_at + 1.minute) do
        put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
      end
      expect(response).to have_http_status(:ok)
      expect(submitter.reload.completed_at).to be_present
      expect(submitter.submission_events.where(event_type: 'complete_form').count).to eq(1)
      expect(consent_events(submitter).order(:id).to_a).to eq(consents)

      # B's per-signer block in the audit trail carries B's own consent line:
      # B's time, once, and never A's (an hour earlier). The event log below
      # the blocks still lists A's consent, in its own shape, so the check is
      # on the per-signer line, not on A's time appearing anywhere.
      audit_trail = submitter.submission.reload.audit_trail
      expect(audit_trail).to be_attached

      text = pdf_text(audit_trail.download)

      expect(text).to match(consent_line(b_consented_at))
      expect(text).not_to match(consent_line(a_consented_at))
      expect(text.scan("#{I18n.t('consented_to_electronic_signatures')} (#{EsignConsent::VERSION}, en):").size)
        .to eq(1)
    end
  end

  describe 'recording' do
    it 'records consent once, at the moment it is first sent, even on a save without completion' do
      submitter = emailed_submitter_for(account)
      consented_at = Time.zone.parse('2026-09-02 10:00:00 UTC')

      travel_to(consented_at) do
        put "/s/#{submitter.slug}",
            params: { values: { text_field(submitter)['uuid'] => 'Jane' }, **consent_params }
      end

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.completed_at).to be_nil
      expect(consent_events(submitter).count).to eq(1)
      expect(consent_events(submitter).sole.event_timestamp).to eq(consented_at)
      expect_consent_data(consent_events(submitter).sole.data, locale: 'en')

      travel_to(consented_at + 1.hour) do
        put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
      end

      expect_completed_with_consent(submitter)
      expect(consent_events(submitter).sole.event_timestamp).to eq(consented_at)

      # A completion without the flag still passes once consent is on record.
      put "/s/#{submitter.slug}", params: completion_params(submitter)
      expect(response.parsed_body).to eq('error' => I18n.t('form_has_been_completed_already'))
    end

    it 'records the locale the disclosure was shown in and the digest of that text' do
      submitter = emailed_submitter_for(account)

      # A French page on an English account: the event names the French text.
      put "/s/#{submitter.slug}", params: completion_params(submitter).merge(consent_params(locale: 'fr'))
      expect_completed_with_consent(submitter, locale: 'fr')

      data = consent_events(submitter).sole.data
      french = Digest::SHA256.hexdigest(I18n.t('esign_consent_disclosure_body_html', locale: :fr))

      expect(data['disclosure_sha256']).to eq(french)
      expect(data['disclosure_sha256']).not_to eq(EsignConsent.disclosure_sha256(version: 'v1', locale: 'en'))
      expect(EsignConsent.disclosure_text(version: 'v1', locale: 'fr'))
        .to eq(I18n.t('esign_consent_disclosure_body_html', locale: :fr))
    end

    it 'falls back to the request locale when the page sends none or one this product does not speak' do
      [[nil, 'en'], %w[xx en], %w[fr-FR fr]].each do |sent, recorded|
        submitter = emailed_submitter_for(account)

        put "/s/#{submitter.slug}", params: completion_params(submitter).merge(consent_params(locale: sent).compact)
        expect_completed_with_consent(submitter, locale: recorded)

        Sidekiq::Worker.clear_all
      end
    end

    # The fallback is the browser locale the signing page rendered under
    # (with_browser_locale covers `update` too), not the account's or English.
    it 'falls back to the browser locale the page was rendered under when it sends none' do
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}", params: completion_params(submitter).merge(consent_params(locale: nil).compact),
                                  headers: { 'HTTP_ACCEPT_LANGUAGE' => 'fr-FR,fr;q=0.9,en;q=0.8' }
      expect_completed_with_consent(submitter, locale: 'fr')
    end

    # A superseded disclosure lives under `esign_disclosure_archive.<version>`
    # (docs §6); the archive is empty today, so a stand-in text is stored for
    # the example and removed again.
    it 'reads a superseded disclosure from the archive scope and fingerprints it' do
      I18n.backend.store_translations(:en, esign_disclosure_archive: { v0: '<p>old</p>' })

      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en')).to eq('<p>old</p>')
      expect(EsignConsent.disclosure_sha256(version: 'v0', locale: 'en')).to eq(Digest::SHA256.hexdigest('<p>old</p>'))
      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'fr')).to be_nil
      expect(EsignConsent.disclosure_text(version: 'v1', locale: 'en')).not_to eq('<p>old</p>')
    ensure
      I18n.backend.translations[:en].delete(:esign_disclosure_archive)
      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en')).to be_nil
    end

    it 'has no digest for a version and locale that were never published' do
      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en')).to be_nil
      expect(EsignConsent.disclosure_sha256(version: 'v0', locale: 'en')).to be_nil
      expect(EsignConsent.disclosure_sha256(version: 'v1', locale: 'xx')).to be_nil
      expect(EsignConsent.disclosure_sha256(version: '../v1', locale: 'en')).to be_nil
    end

    it 'exposes the consent version, locale and disclosure digest through the API event data' do
      submitter = emailed_submitter_for(paid_account)

      put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
      expect_completed_with_consent(submitter)

      # The API show endpoint renders the signed result on read, so it signs.
      platform_certificate!

      get "/api/submitters/#{submitter.id}", headers: token_headers(paid_account)

      event = response.parsed_body['submission_events'].find { |e| e['event_type'] == 'esign_consent' }

      expect(event).to be_present
      expect(event['data']).to eq('version' => 'v1', 'locale' => 'en',
                                  'disclosure_sha256' => EsignConsent.disclosure_sha256(version: 'v1', locale: 'en'))
    end
  end

  describe 'sender-attested exemption' do
    def expect_sender_attested(submitter)
      expect(submitter.reload.completed_at).to be_present
      expect(consent_events(submitter)).not_to exist
      expect(submitter.submission_events.where(event_type: 'api_complete_form')).to exist
    end

    # The API is a paid surface (gating_spec); the exemption is about the
    # completion, not the plan.
    it 'completes PUT /api/submitters/:id completed: true with zero consent events' do
      submitter = emailed_submitter_for(paid_account)

      put "/api/submitters/#{submitter.id}", headers: token_headers(paid_account).merge(json_headers),
                                             params: { completed: true }.to_json

      expect(response).to have_http_status(:ok)
      expect_sender_attested(submitter)
    end

    it 'completes POST /api/submissions completed: true with zero consent events' do
      template = text_template_for(paid_account)

      post '/api/submissions', headers: token_headers(paid_account).merge(json_headers), params: {
        template_id: template.id,
        submitters: [{ role: template.submitters.first['name'], email: 'signer@example.com', completed: true }]
      }.to_json

      expect(response).to have_http_status(:ok)
      expect_sender_attested(Submission.last.submitters.sole)
    end

    it 'completes a signing session created completed: true with zero consent events' do
      create_signing_session(paid_account, token_headers(paid_account), completed: true)

      expect(response).to have_http_status(:ok)
      expect_sender_attested(Submission.last.submitters.sole)
    end
  end

  describe 'locales' do
    it 'resolves every consent string in every declared locale, translated for non-English ones' do
      english = %w[esign_consent_checkbox_label esign_consent_disclosure_body_html
                   esign_consent_version_stale].index_with do |key|
        I18n.t(key, locale: :en)
      end

      I18n.available_locales.each do |locale|
        ConsentSpecSupport::CONSENT_KEYS.each do |key|
          value = I18n.t(key, locale:, fallback: false, raise: true, version: 'v1', submitter_name: 'Jane')

          expect(value).to be_a(String), "#{locale} #{key}"
          expect(value).to be_present, "#{locale} #{key}"
        end

        expect(I18n.t('submission_event_names.esign_consent_by_html', locale:, version: 'v1', submitter_name: 'J'))
          .to match(%r{<b>.*v1.*</b>.*J}), locale.to_s
        expect { I18n.l(EsignConsent::EFFECTIVE_DATE, format: :long, locale:) }.not_to raise_error, locale.to_s

        next if locale.to_s.start_with?('en')

        english.each do |key, english_value|
          expect(I18n.t(key, locale:)).not_to eq(english_value), "#{locale} #{key} is an English copy"
        end
      end
    end
  end

  describe 'audit trail', sidekiq: :inline do
    let(:timeline_types) { %w[send_email bounce_email complaint_email open_email click_email] }
    let(:tracking_labels) { ['Email opened', 'Email link clicked', 'Email bounced', 'Spam complaint'] }

    %i[account paid_account internal_account].each do |actor|
      it "gates tracking in #{actor}'s signed audit PDF without removing signing evidence" do
        platform_certificate!
        owner = public_send(actor)
        # Internal accounts sign with their own certificate row, never the platform one.
        if owner.internal?
          create(:encrypted_config, account: owner, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                    value: GenerateCertificate.call.transform_values(&:to_pem))
        end
        submitter = emailed_submitter_for(owner)
        timeline_types.each do |type|
          SubmissionEvent.create!(submitter:, event_type: type, data: { email: submitter.email })
        end

        put "/s/#{submitter.slug}", params: completion_params(submitter).merge(consent_params)

        expect(response).to have_http_status(:ok)
        audit_trail = submitter.submission.reload.audit_trail
        expect(audit_trail).to be_attached
        text = pdf_text(audit_trail.download)
        expect(text).to match(pdf_phrase('Email sent'))
        # The emailed-link click is signing EVIDENCE (the verification line), not
        # delivery tracking: it prints on every plan.
        expect(text).to match(pdf_phrase('Email verification'))
        expect(text).to include(I18n.t('consented_to_electronic_signatures', locale: :en))
        expect(text).not_to match(/translation missing/i)

        tracking_labels.each do |label|
          if actor == :account
            expect(text).not_to match(pdf_phrase(label))
          else
            expect(text).to match(pdf_phrase(label))
          end
        end
      end
    end

    it 'prints the consent line in each base locale and never a missing translation' do
      platform_certificate!

      ConsentSpecSupport::BASE_LOCALES.each do |locale|
        account.update!(locale:)
        submitter = emailed_submitter_for(account)

        put "/s/#{submitter.slug}", params: completion_params(submitter).merge(consent_params(locale:))

        expect(response).to have_http_status(:ok), locale
        expect(submitter.reload.completed_at).to be_present, locale
        expect_consent_data(consent_events(submitter).sole.data, locale:)

        audit_trail = submitter.submission.reload.audit_trail

        expect(audit_trail).to be_attached, locale

        text = pdf_text(audit_trail.download)

        expect(text).not_to match(/translation missing/i), "#{locale}: #{text[/.{0,40}translation missing.{0,60}/i]}"
        expect(text).to include(I18n.t('consented_to_electronic_signatures', locale:)), locale
        expect(text).to include("(#{EsignConsent::VERSION}, #{locale})"), locale
      end
    end
  end
end
