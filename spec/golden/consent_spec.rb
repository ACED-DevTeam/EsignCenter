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
  # The literal placeholder, spelled out so rubocop does not read it as a
  # format token: an interpolated disclosure must never still contain it.
  SENDER_PLACEHOLDER = ['%', '{sender_name}'].join.freeze
  BASE_LOCALES = %w[en es it fr pt de pl uk cs he nl ar ko ja].freeze
  CONSENT_KEYS = %w[esign_consent_checkbox_label esign_consent_disclosure_link esign_consent_disclosure_title
                    esign_consent_disclosure_body_html esign_consent_version_label esign_consent_required
                    esign_consent_version_stale esign_consent_view_pdf esign_consent_open_pdf_first
                    esign_consent_shown_to esign_consent_sender_not_recorded esign_consent_pdf_opened
                    esign_consent_pdf_not_opened esign_consent_pdf_not_recorded esign_consent_the_sender
                    esign_consent_document_too_many_requests esign_consent_view_first_pdf
                    consented_to_electronic_signatures close
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

  # The consent always travels with the version the form displayed, the locale
  # it was displayed in AND the server's signed token for that locale, and a
  # fingerprint of the sender it named (consent_version_spec proves each of
  # the four is binding).
  def consent_params(submitter = nil, locale: 'en', pdf_opened: 'true')
    { esign_consent: 'true', esign_consent_version: EsignConsent::VERSION, esign_consent_locale: locale,
      esign_consent_locale_token: submitter && locale && EsignConsent.locale_token(submitter, locale),
      esign_consent_pdf_opened: pdf_opened,
      esign_consent_sender_digest: submitter && EsignConsent.sender_digest(submitter) }.compact
  end

  def completion_params(submitter, esign_consent: nil)
    params = { completed: 'true', values: { text_field(submitter)['uuid'] => 'Jane' } }

    esign_consent ? params.merge(consent_params(submitter)) : params
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

  def expect_completed_with_consent(submitter, locale: 'en', pdf_opened: true)
    expect(response).to have_http_status(:ok)
    expect(submitter.reload.completed_at).to be_present
    expect(submitter.submission_events.where(event_type: 'complete_form').count).to eq(1)
    expect(consent_events(submitter).count).to eq(1)
    expect_consent_data(consent_events(submitter).sole.data, locale:, pdf_opened:)
  end

  # The event names the exact text the signer agreed to: version, locale and
  # the digest of the disclosure TEMPLATE in that locale, which must be the one
  # EsignConsent recomputes from the locale data (a later verifier's check),
  # plus the sender details the template was filled in with (server-side) and
  # the browser's claim about the PDF link.
  def expect_consent_data(data, locale:, pdf_opened: true)
    expect(data).to include('version' => EsignConsent::VERSION, 'locale' => locale, 'pdf_opened' => pdf_opened)
    expect(data['sender_name']).to be_present
    expect(data['sender_email']).to match(/\A[^@\s]+@[^@\s]+\z/)
    expect(data['disclosure_sha256']).to match(/\A\h{64}\z/)
    expect(data['disclosure_sha256']).to eq(EsignConsent.disclosure_sha256(version: EsignConsent::VERSION, locale:))
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

  # What the trail actually draws for a translated string: RTL text is
  # reordered visually on the way into the PDF (TextUtils.maybe_rtl_reverse),
  # LTR text is untouched.
  def rtl(text)
    TextUtils.maybe_rtl_reverse(text)
  end

  # A phrase as it may come back out of the PDF: line wraps fall between
  # words and the collector keeps no whitespace across them.
  def pdf_phrase(text)
    Regexp.new(text.split(/\s+/).map { |word| Regexp.escape(word) }.join('\s*'))
  end

  # The per-signer audit line for a consent given at `time`
  # ("Consented to electronic signatures (v2, en): September 01, 2026 10:00").
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

      post "/s/#{submitter.slug}/invite", params: invite.merge(consent_params(submitter))
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
        put "/s/#{old_slug}",
            params: { values: { text_field(submitter)['uuid'] => 'Jane' }, **consent_params(submitter) }
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
        put "/s/#{submitter.slug}",
            params: { values: { text_field(submitter)['uuid'] => 'Jane' }, **consent_params(submitter) }
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
            params: { values: { text_field(submitter)['uuid'] => 'Jane' }, **consent_params(submitter) }
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
      # The locale on the record is the one the SERVER signed a token for when
      # it rendered the page (B3), so only a page that really was French can
      # get the French digest filed (consent_version_spec proves the binding).
      put "/s/#{submitter.slug}", headers: { 'HTTP_ACCEPT_LANGUAGE' => 'fr-FR,fr;q=0.9' },
                                  params: completion_params(submitter).merge(consent_params(submitter, locale: 'fr'))
      expect_completed_with_consent(submitter, locale: 'fr')

      data = consent_events(submitter).sole.data
      french = Digest::SHA256.hexdigest(I18n.t('esign_consent_disclosure_body_html', locale: :fr))

      expect(data['disclosure_sha256']).to eq(french)
      expect(data['disclosure_sha256']).not_to eq(EsignConsent.disclosure_sha256(version: EsignConsent::VERSION,
                                                                                 locale: 'en'))
      expect(EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale: 'fr'))
        .to eq(I18n.t('esign_consent_disclosure_body_html', locale: :fr))
    end

    it 'falls back to the request locale when the page sends none, and refuses one it cannot vouch for' do
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}",
          params: completion_params(submitter).merge(consent_params(submitter, locale: nil).compact)
      expect_completed_with_consent(submitter, locale: 'en')

      Sidekiq::Worker.clear_all

      # A locale this product does not speak has no disclosure and so no
      # token: nothing vouches for it, and the consent is refused rather than
      # quietly filed against a text the page cannot have shown.
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}",
          params: completion_params(submitter).merge(consent_params(submitter, locale: 'xx').compact)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_version_stale')
      expect(consent_events(submitter)).not_to exist
      expect(submitter.reload.completed_at).to be_nil

      # A regional variant names the same base locale, so a French page told
      # `fr-FR` is agreed with, not refused, and files `fr`.
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}", headers: { 'HTTP_ACCEPT_LANGUAGE' => 'fr-FR,fr;q=0.9' },
                                  params: completion_params(submitter).merge(consent_params(submitter,
                                                                                            locale: 'fr-FR'))
      expect_completed_with_consent(submitter, locale: 'fr')
    end

    # The fallback is the browser locale the signing page rendered under
    # (with_browser_locale covers `update` too), not the account's or English.
    it 'falls back to the browser locale the page was rendered under when it sends none' do
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}",
          params: completion_params(submitter).merge(consent_params(submitter, locale: nil).compact),
          headers: { 'HTTP_ACCEPT_LANGUAGE' => 'fr-FR,fr;q=0.9,en;q=0.8' }
      expect_completed_with_consent(submitter, locale: 'fr')
    end

    # A superseded disclosure lives under `esign_disclosure_archive.<version>`
    # (docs §6). v1 is really archived there (the example below reads it back);
    # this one proves the mechanism for a version that never shipped, with a
    # stand-in text stored for the example and removed again — only the v0 key,
    # so the real v1 archive survives the cleanup.
    it 'reads a superseded disclosure from the archive scope and fingerprints it' do
      I18n.backend.store_translations(:en, esign_disclosure_archive: { v0: '<p>old</p>' })

      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en')).to eq('<p>old</p>')
      expect(EsignConsent.disclosure_sha256(version: 'v0', locale: 'en')).to eq(Digest::SHA256.hexdigest('<p>old</p>'))
      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'fr')).to be_nil
      expect(EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale: 'en')).not_to eq('<p>old</p>')
    ensure
      I18n.backend.translations[:en][:esign_disclosure_archive]&.delete(:v0)
      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en')).to be_nil
      expect(EsignConsent.disclosure_text(version: 'v1', locale: 'en')).to be_present
    end

    # v1 is the launch disclosure, superseded on 2026-09-05 (docs §6). Its text
    # has to stay readable for every locale a v1 consent could have been given
    # in, or the events on record stop being answerable.
    it 'reads the archived v1 disclosure back for every base locale, with a digest' do
      ConsentSpecSupport::BASE_LOCALES.each do |locale|
        text = EsignConsent.disclosure_text(version: 'v1', locale:)

        expect(text).to be_present, locale
        expect(text).to start_with('<p>'), locale
        expect(text).not_to eq(EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale:)), locale
        expect(EsignConsent.disclosure_sha256(version: 'v1', locale:))
          .to eq(Digest::SHA256.hexdigest(text)), locale
      end

      # The archive never shadows the live key, in either direction.
      expect(EsignConsent.disclosure_text(version: 'v1', locale: 'fr'))
        .to eq(I18n.t('esign_disclosure_archive.v1', locale: :fr))
      expect(I18n.t('esign_consent_disclosure_body_html', locale: :fr))
        .to eq(EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale: 'fr'))
    end

    it 'has no digest for a version and locale that were never published' do
      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en')).to be_nil
      expect(EsignConsent.disclosure_sha256(version: 'v0', locale: 'en')).to be_nil
      expect(EsignConsent.disclosure_sha256(version: EsignConsent::VERSION, locale: 'xx')).to be_nil
      expect(EsignConsent.disclosure_sha256(version: '../v2', locale: 'en')).to be_nil
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
      expect(event['data'])
        .to eq('version' => EsignConsent::VERSION, 'locale' => 'en',
               'disclosure_sha256' => EsignConsent.disclosure_sha256(version: EsignConsent::VERSION, locale: 'en'),
               'sender_name' => paid_account.name,
               'sender_email' => admin_for(paid_account).email,
               'pdf_opened' => true)
    end
  end

  # D77 A: the disclosure names the sender and links to the document itself.
  describe 'the sender named in the disclosure' do
    it 'fills the modal with the sending account and a reply-to address, escaped' do
      account.update!(name: 'Acme <Legal> Ltd')
      submitter = emailed_submitter_for(account)

      get "/s/#{submitter.slug}"

      expect(response).to have_http_status(:ok)

      body = response.body

      expect(body).to include(ERB::Util.html_escape('Acme <Legal> Ltd'))
      expect(body).to include(admin_for(account).email)
      expect(body).not_to include(ConsentSpecSupport::SENDER_PLACEHOLDER)
      expect(body).not_to include('<Legal>')
    end

    it 'prefers the signer\'s reply-to address and never a no-reply one' do
      submitter = emailed_submitter_for(account)

      expect(EsignConsent.sender_email(submitter)).to eq(admin_for(account).email)

      submitter.update!(preferences: { 'reply_to' => 'Contracts <contracts@acme.example>' })
      expect(EsignConsent.sender_email(submitter.reload)).to eq('contracts@acme.example')

      submitter.update!(preferences: { 'reply_to' => 'no-reply@acme.example' })
      expect(EsignConsent.sender_email(submitter.reload)).to eq(admin_for(account).email)
    end

    it 'records the sender as shown and the browser\'s PDF claim, false included' do
      platform_certificate!
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}",
          params: completion_params(submitter).merge(consent_params(submitter, pdf_opened: 'false'))

      expect_completed_with_consent(submitter, pdf_opened: false)
      expect(consent_events(submitter).sole.data)
        .to include('sender_name' => account.name, 'sender_email' => admin_for(account).email)
    end

    # "Did not open it" is evidence too: the trail says so rather than staying
    # silent, which a reader could take for "not recorded".
    it 'prints the not-opened line in the audit trail when the browser said no', sidekiq: :inline do
      platform_certificate!
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}",
          params: completion_params(submitter).merge(consent_params(submitter, pdf_opened: 'false'))

      expect(response).to have_http_status(:ok)

      text = pdf_text(submitter.submission.reload.audit_trail.download)

      expect(text).to match(pdf_phrase(I18n.t('esign_consent_pdf_not_opened')))
      expect(text).not_to match(pdf_phrase(I18n.t('esign_consent_pdf_opened')))
      expect(text).not_to match(pdf_phrase(I18n.t('esign_consent_pdf_not_recorded')))
    end

    # A consent recorded before this product asked the question carries no
    # `pdf_opened` key at all. Absent is not "no": the trail says the answer
    # was never recorded rather than asserting, in a signed PDF, that the
    # signer did not open it.
    it 'prints the not-recorded line for a consent that never carried the answer', sidekiq: :inline do
      platform_certificate!
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')

      expect(response).to have_http_status(:ok)

      event = consent_events(submitter).sole
      event.update!(data: event.data.except('pdf_opened'))

      submission = submitter.submission.reload
      submission.audit_trail_attachment.destroy!
      Submissions::GenerateAuditTrail.call(submission)

      text = pdf_text(submission.reload.audit_trail.download)

      expect(text).to match(pdf_phrase(I18n.t('esign_consent_pdf_not_recorded')))
      expect(text).not_to match(pdf_phrase(I18n.t('esign_consent_pdf_not_opened')))
      expect(text).not_to match(pdf_phrase(I18n.t('esign_consent_pdf_opened')))
    end

    # N1: with nothing to serve the page draws no "View this document as a PDF"
    # link, so it never asks the question and its form posts no answer. The
    # record must leave the key off rather than file `false` — a signed PDF
    # saying the signer declined to open a link they were never shown is the
    # same invented statement the not-recorded line exists to prevent.
    it 'records no PDF claim, and says so in the trail, when no link was offered', sidekiq: :inline do
      platform_certificate!
      template = create(:template, account:, author: admin_for(account), submitter_count: 2,
                                   only_field_types: %w[text])
      submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))
      first, second = submission.submitters.order(:id).to_a
      [first, second].each { |s| s.update!(sent_at: Time.current) }

      schema = submission.template_schema.presence || submission.template.schema
      condition = { 'field_uuid' => text_field(second)['uuid'], 'action' => 'not_empty' }

      submission.update!(template_schema: schema.map { |item| item.merge('conditions' => [condition]) })

      get "/s/#{first.slug}"

      expect(response).to have_http_status(:ok)
      expect(esign_consent_contract['pdf_url']).to be_nil

      # Exactly what that page's form sends: it carries no pdf_opened field.
      [first, second].each do |signer|
        put "/s/#{signer.slug}",
            params: completion_params(signer).merge(consent_params(signer).except(:esign_consent_pdf_opened))

        expect(response).to have_http_status(:ok), signer.slug
        expect(consent_events(signer).sole.data).not_to have_key('pdf_opened')
      end

      text = pdf_text(submission.reload.audit_trail.download)

      expect(text).to match(pdf_phrase(I18n.t('esign_consent_pdf_not_recorded')))
      expect(text).not_to match(pdf_phrase(I18n.t('esign_consent_pdf_not_opened')))
      expect(text).not_to match(pdf_phrase(I18n.t('esign_consent_pdf_opened')))
    end
  end

  # D77 A review: no signed PDF and no modal may ever show a raw placeholder,
  # and a sender's own name must survive the trip through the plain-text path.
  describe 'the sender never printed as a placeholder' do
    # `accounts.name` is NOT NULL, so an unnamed account cannot be saved — the
    # fallbacks are defence in depth for a signed PDF that must never read
    # "sent by ". Asserted in memory, where a blank name is reachable.
    it 'falls back through account name, sender full name and the product name' do
      submitter = emailed_submitter_for(account)
      admin = admin_for(account)

      expect(EsignConsent.sender_name(submitter)).to eq(account.name)

      submitter.submission.account.name = ''
      expect(EsignConsent.sender_name(submitter)).to eq(admin.full_name)

      submitter.submission.created_by_user.first_name = ''
      submitter.submission.created_by_user.last_name = ''
      expect(EsignConsent.sender_name(submitter)).to eq(Docuseal.product_name)
      expect(EsignConsent.sender_name(submitter)).to be_present
    end

    it 'never puts a placeholder in the modal' do
      submitter = emailed_submitter_for(account)

      get "/s/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(ConsentSpecSupport::SENDER_PLACEHOLDER)
      expect(response.body).to include(ERB::Util.html_escape(EsignConsent.sender_name(submitter)))
    end

    # strip_tags would eat `<Legal>` if the sender went into the template
    # before the markup came off, so the plain-text path strips first.
    it 'keeps angle brackets and ampersands in the sender name out of the plain-text path' do
      name = 'Acme <Legal> & Co'
      paragraphs = EsignConsent.disclosure_paragraphs(
        EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale: 'en'),
        sender_name: name, sender_email: 'legal@acme.example'
      )
      text = paragraphs.join(' ')

      expect(paragraphs.size).to eq(9)
      expect(text).to include(name)
      # The template's own markup is gone; every one of the nine places the
      # disclosure names the sender still has the brackets it was given.
      expect(text).not_to include('<strong>')
      expect(text).not_to include('<p>')
      expect(text.scan('<Legal>').size).to eq(9)
      expect(text.scan('<').size).to eq(9)
      expect(text).not_to include(ConsentSpecSupport::SENDER_PLACEHOLDER)
    end

    # The modal is HTML, so there the same name is escaped rather than kept raw.
    it 'escapes the sender name in the modal' do
      account.update!(name: 'Acme <Legal> & Co')
      submitter = emailed_submitter_for(account)
      html = EsignConsent.disclosure_html(submitter, locale: 'en')

      expect(html).to include('Acme &lt;Legal&gt; &amp; Co')
      expect(html).not_to include('<Legal>')
    end
  end

  # One resolver behind the invitation's Reply-To header and the address the
  # disclosure tells the signer to write to (Submitters::ReplyTo).
  describe 'the disclosure address is the invitation reply-to' do
    def modal_sender_email(submitter)
      get "/s/#{submitter.slug}"

      EsignConsent.sender_email(submitter)
    end

    def invitation_reply_to(submitter)
      SubmitterMailer.invitation_email(submitter).reply_to&.first
    end

    it 'matches for a custom reply-to on the signer' do
      submitter = emailed_submitter_for(account)
      submitter.update!(preferences: { 'reply_to' => 'Contracts <contracts@acme.example>' })

      expect(invitation_reply_to(submitter)).to eq('contracts@acme.example')
      expect(modal_sender_email(submitter)).to eq('contracts@acme.example')
    end

    it 'matches when there is no custom reply-to and falls to the sending user' do
      submitter = emailed_submitter_for(account)

      expect(invitation_reply_to(submitter)).to eq(admin_for(account).email)
      expect(modal_sender_email(submitter)).to eq(admin_for(account).email)
    end

    # The sender signing their own document: replying to themselves reaches
    # nobody, so the chain moves on to the account's first administrator.
    # Where the two halves part company: a mail carries no Reply-To rather than
    # publish this account's own administrator mailbox, but the disclosure must
    # still name somebody the signer can write to.
    it 'leaves the header off for a self-signed document and shows the admin in the disclosure' do
      other_admin = create(:user, account:)
      submitter = emailed_submitter_for(account)
      submitter.update!(email: admin_for(account).email)

      expected = [admin_for(account), other_admin].min_by(&:id).email

      expect(invitation_reply_to(submitter.reload)).to be_nil
      expect(modal_sender_email(submitter)).to eq(expected)
    end

    it 'leaves the header off for a configured no-reply address and shows the admin in the disclosure' do
      submitter = emailed_submitter_for(account)
      submitter.update!(preferences: { 'reply_to' => 'no-reply@acme.example' })

      expect(invitation_reply_to(submitter.reload)).to be_nil
      expect(modal_sender_email(submitter)).to eq(admin_for(account).email)
    end

    it 'keeps the display name on the header and prints the bare address in the disclosure' do
      submitter = emailed_submitter_for(account)
      submitter.update!(preferences: { 'reply_to' => 'Contracts Team <contracts@acme.example>' })

      mail = SubmitterMailer.invitation_email(submitter.reload)

      expect(mail[:reply_to].to_s).to include('Contracts Team')
      expect(mail.reply_to).to eq(['contracts@acme.example'])
      expect(modal_sender_email(submitter)).to eq('contracts@acme.example')
    end

    # A documents-copy mail with no copy address of its own keeps behaving as
    # it did: it never borrows the invitation copy's reply-to.
    it 'does not lend the invitation reply-to to a documents-copy mail' do
      platform_certificate!
      submitter = emailed_submitter_for(paid_account)
      create(:account_config, account: paid_account, key: AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                              value: { 'subject' => 'Please sign', 'body' => 'Hello {{submitter.link}}',
                                       'reply_to' => 'invites@acme.example' })

      put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
      expect(submitter.reload.completed_at).to be_present

      expect(SubmitterMailer.invitation_email(submitter).reply_to).to eq(['invites@acme.example'])
      expect(SubmitterMailer.documents_copy_email(submitter).reply_to)
        .to eq([admin_for(paid_account).email])
    end
  end

  describe 'the document PDF door (/s/:slug/document.pdf)' do
    # One PDF and nothing to merge: the door hands the browser a short-lived
    # signed storage link rather than reading the file through the app.
    it 'redirects a single-PDF form to the file, served inline, and 404s for an unknown slug' do
      submitter = emailed_submitter_for(account)

      get "/s/#{submitter.slug}/document.pdf"

      expect(response).to have_http_status(:found)
      expect(response.location).to include('disposition=inline')

      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/pdf')
      expect(response.headers['Content-Disposition']).to start_with('inline')
      expect(response.body[0, 5]).to eq('%PDF-')

      get '/s/does-not-exist/document.pdf'

      expect(response).to have_http_status(:not_found)
    end

    # Over the cap the first document alone is served, and the link says so.
    it 'serves the first document only when the documents are too big to merge' do
      template = create(:template, account:, author: admin_for(account), attachment_count: 2,
                                   only_field_types: %w[text])
      submitter = emailed_submitter_for(account, template:)
      documents = Submissions::OriginalDocumentPdf.attachments_for(submitter.submission)

      expect(documents.size).to eq(2)
      expect(Submissions::OriginalDocumentPdf.truncated?(documents)).to be(false)

      stub_const('Submissions::OriginalDocumentPdf::MERGE_SIZE_LIMIT', 1)

      expect(Submissions::OriginalDocumentPdf.truncated?(documents)).to be(true)
      expect(Submissions::OriginalDocumentPdf.servable(documents)).to eq(documents.first(1))

      # The one document left is a PDF, so it goes out as a signed link.
      get "/s/#{submitter.slug}/document.pdf"
      expect(response).to have_http_status(:found)

      # And the link on the form says what it will actually hand over.
      get "/s/#{submitter.slug}"
      expect(esign_consent_contract['view_pdf_text']).to eq(I18n.t('esign_consent_view_first_pdf'))
    end

    it 'merges both documents, and promises the whole thing, when the cap does not bite' do
      template = create(:template, account:, author: admin_for(account), attachment_count: 2,
                                   only_field_types: %w[text])
      submitter = emailed_submitter_for(account, template:)

      get "/s/#{submitter.slug}/document.pdf"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/pdf')
      expect(response.body[0, 5]).to eq('%PDF-')

      get "/s/#{submitter.slug}"
      expect(esign_consent_contract['view_pdf_text']).to eq(I18n.t('esign_consent_view_pdf'))
    end

    it 'refuses a signer who has already completed, like the page redirects one' do
      submitter = emailed_submitter_for(account)

      put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
      expect(submitter.reload.completed_at).to be_present

      get "/s/#{submitter.slug}/document.pdf"

      expect(response).to have_http_status(:not_found)
    end

    # The signing page itself refuses until the emailed code is entered; the
    # document door has to refuse on the same terms or it would route around it.
    it 'refuses an email-2FA protected document until the code has been verified' do
      template = text_template_for(account)
      template.update!(preferences: { 'require_email_2fa' => true })
      submitter = emailed_submitter_for(account, template:)

      get "/s/#{submitter.slug}/document.pdf"
      expect(response).to have_http_status(:not_found)

      code = EmailVerificationCodes.generate([submitter.email.downcase.strip, submitter.slug].join(':'))
      post '/submit_form_email_2fa', params: { submitter_slug: submitter.slug, one_time_code: code }

      get "/s/#{submitter.slug}/document.pdf"
      expect(response).to have_http_status(:found)
    end

    # The builder's dry run shows the same gate, so its link has to answer too.
    it 'serves the template copy to the sender and refuses another account' do
      template = text_template_for(account)

      act_as(account)
      get "/templates/#{template.id}/form_document.pdf"

      expect(response).to have_http_status(:found)

      follow_redirect!

      expect(response.media_type).to eq('application/pdf')

      act_as(paid_account)
      get "/templates/#{template.id}/form_document.pdf"

      expect(response).not_to have_http_status(:ok)
    end

    # The door and the signing page share one predicate (Submitters::FormOpen),
    # so every state that closes the form closes the door.
    describe 'refusing exactly what the signing page refuses' do
      def expect_door_refused(submitter)
        get "/s/#{submitter.slug}/document.pdf"

        expect(response).to have_http_status(:not_found)
      end

      # Each of the four states Submitters::FormOpen#locked? asks about, closed
      # one at a time on an otherwise open form: whichever one it is, the door
      # 404s.
      {
        'an archived account' => ->(submitter) { submitter.account.update!(archived_at: Time.current) },
        'a declined signer' => ->(submitter) { submitter.update!(declined_at: Time.current) },
        'an expired submission' => ->(submitter) { submitter.submission.update!(expire_at: 1.day.ago) },
        'an archived template' => ->(submitter) { submitter.submission.template.update!(archived_at: Time.current) }
      }.each do |description, close_the_form|
        it "refuses #{description}" do
          submitter = emailed_submitter_for(account)
          close_the_form.call(submitter)

          expect_door_refused(submitter)
        end
      end

      it 'refuses a signer whose turn has not come under an enforced order' do
        template = create(:template, account:, author: admin_for(account), submitter_count: 2,
                                     only_field_types: %w[text])
        create(:account_config, account:, key: AccountConfig::ENFORCE_SIGNING_ORDER_KEY, value: true)

        submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))
        first, second = submission.submitters.order(:id).to_a

        # The signing page itself puts up the "awaiting" page for the second.
        get "/s/#{second.slug}"
        expect(response.body).to include(I18n.t('awaiting_completion_by_the_other_party'))

        expect_door_refused(second)

        get "/s/#{first.slug}/document.pdf"
        expect(response).to have_http_status(:found)
      end
    end

    # Only what the page shows: the door's documents are the SIGNING PAGE's
    # filtered schema, uuid for uuid and in its order — asserted against the
    # page's own expression (values merged across the submitters, the signer's
    # uuid included), never against the door's own body.
    it 'serves exactly the schema the signing page filters, in its order' do
      submitter = emailed_submitter_for(account)
      submission = submitter.submission
      values = submission.submitters.reduce({}) { |acc, sub| acc.merge(sub.values) }
      page_schema = Submissions.filtered_conditions_schema(submission, values:,
                                                                       include_submitter_uuid: submitter.uuid)

      expect(page_schema.pluck('attachment_uuid')).to be_present
      expect(Submissions::OriginalDocumentPdf.attachments_for(submission, submitter:).map(&:uuid))
        .to eq(page_schema.pluck('attachment_uuid'))
    end

    # The condition the signer's own empty field puts on the document they are
    # looking at. The page treats it as satisfied — the field is the one they
    # are about to fill in — so the door must too: filtering the schema without
    # the signer's uuid 404s the document on screen in front of them, with the
    # consent checkbox still holding them behind the link.
    it 'agrees with the page on a document conditional on the signer\'s own field' do
      submitter = emailed_submitter_for(account)
      submission = submitter.submission
      schema = submission.template_schema.presence || submission.template.schema
      condition = { 'field_uuid' => text_field(submitter)['uuid'], 'action' => 'not_empty' }

      submission.update!(template_schema: schema.map { |item| item.merge('conditions' => [condition]) })

      # What the page renders: the form's own data-schema attribute.
      get "/s/#{submitter.slug}"

      rendered = JSON.parse(Nokogiri::HTML(response.body).at_css('submission-form')['data-schema'])

      expect(rendered.pluck('attachment_uuid')).to eq(schema.pluck('attachment_uuid'))

      # ...and what the door serves, for the same signer.
      expect(Submissions::OriginalDocumentPdf.attachments_for(submission.reload, submitter:).map(&:uuid))
        .to eq(rendered.pluck('attachment_uuid'))

      get "/s/#{submitter.slug}/document.pdf"

      expect(response).to have_http_status(:found)
    end

    # The other half of the same rule: a condition on somebody ELSE's empty
    # field really does exclude the document, from the page and from the door
    # alike, and with nothing left to serve the door 404s.
    it 'excludes a document the page excludes, and then has nothing to serve' do
      template = create(:template, account:, author: admin_for(account), submitter_count: 2,
                                   only_field_types: %w[text])
      submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))
      first, second = submission.submitters.order(:id).to_a
      first.update!(sent_at: Time.current, email: 'signer@example.com')

      schema = submission.template_schema.presence || submission.template.schema
      condition = { 'field_uuid' => text_field(second)['uuid'], 'action' => 'not_empty' }

      submission.update!(template_schema: schema.map { |item| item.merge('conditions' => [condition]) })

      get "/s/#{first.slug}"

      expect(JSON.parse(Nokogiri::HTML(response.body).at_css('submission-form')['data-schema'])).to be_empty
      expect(Submissions::OriginalDocumentPdf.attachments_for(submission.reload, submitter: first)).to be_empty

      get "/s/#{first.slug}/document.pdf"

      expect(response).to have_http_status(:not_found)
    end

    # Nothing to serve means no link at all: the gate is
    # `!!config.pdf_url && !pdfOpened`, so a signer is never held behind a
    # "View this document as a PDF" link that can only 404.
    it 'offers no PDF link, and no gate, when there is nothing to serve' do
      template = create(:template, account:, author: admin_for(account), submitter_count: 2,
                                   only_field_types: %w[text])
      submission = create(:submission, :with_submitters, template:, created_by_user: admin_for(account))
      first, second = submission.submitters.order(:id).to_a
      first.update!(sent_at: Time.current, email: 'signer@example.com')

      schema = submission.template_schema.presence || submission.template.schema
      condition = { 'field_uuid' => text_field(second)['uuid'], 'action' => 'not_empty' }

      submission.update!(template_schema: schema.map { |item| item.merge('conditions' => [condition]) })

      get "/s/#{first.slug}"

      expect(response).to have_http_status(:ok)
      expect(esign_consent_contract['pdf_url']).to be_nil
    end

    it 'refuses a slug that asks too often, with a readable message' do
      submitter = emailed_submitter_for(account)

      SubmitFormDocumentController::REQUESTS_PER_SLUG_PER_HOUR.times do
        get "/s/#{submitter.slug}/document.pdf"
        expect(response).to have_http_status(:found)
      end

      get "/s/#{submitter.slug}/document.pdf"

      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to eq(I18n.t('esign_consent_document_too_many_requests'))
    end

    it 'hands the signing form the link and the two gate strings' do
      submitter = emailed_submitter_for(account)

      get "/s/#{submitter.slug}"

      expect(esign_consent_contract)
        .to include('pdf_url' => "/s/#{submitter.slug}/document.pdf",
                    'view_pdf_text' => I18n.t('esign_consent_view_pdf'),
                    'open_pdf_first' => I18n.t('esign_consent_open_pdf_first'))
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
                   esign_consent_version_stale esign_consent_view_pdf
                   esign_consent_open_pdf_first esign_consent_pdf_opened
                   esign_consent_pdf_not_opened esign_consent_pdf_not_recorded esign_consent_the_sender
                   esign_consent_document_too_many_requests esign_consent_view_first_pdf
                   esign_consent_shown_to esign_consent_sender_not_recorded].index_with do |key|
        I18n.t(key, locale: :en)
      end

      I18n.available_locales.each do |locale|
        ConsentSpecSupport::CONSENT_KEYS.each do |key|
          value = I18n.t(key, locale:, fallback: false, raise: true, version: EsignConsent::VERSION,
                              submitter_name: 'Jane', sender_name: 'Acme Ltd',
                              sender_email: 'acme@example.com', product_name: Docuseal.product_name)

          expect(value).to be_a(String), "#{locale} #{key}"
          expect(value).to be_present, "#{locale} #{key}"
        end

        expect(I18n.t('submission_event_names.esign_consent_by_html', locale:, version: EsignConsent::VERSION,
                                                                      submitter_name: 'J'))
          .to match(%r{<b>.*#{EsignConsent::VERSION}.*</b>.*J}o), locale.to_s
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

        put "/s/#{submitter.slug}", params: completion_params(submitter).merge(consent_params(submitter))

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

    # A3.2: the audit trail carries the disclosure itself, so the evidence does
    # not depend on anyone still having the product to look the text up in.
    %w[en he ar ja].each do |locale|
      it "reproduces the #{locale} disclosure in the audit trail appendix" do
        platform_certificate!
        account.update!(locale:, name: 'Acme Ltd')
        submitter = emailed_submitter_for(account)

        put "/s/#{submitter.slug}", headers: { 'HTTP_ACCEPT_LANGUAGE' => locale },
                                    params: completion_params(submitter).merge(consent_params(submitter, locale:))

        expect(response).to have_http_status(:ok), locale

        text = pdf_text(submitter.submission.reload.audit_trail.download)

        # HexaPDF does no bidi of its own, so every translated string the trail
        # draws is reversed on the way in; he and ar must come back out of the
        # PDF in exactly that form, the same as the trail's other RTL strings.
        expect(text).to match(pdf_phrase(rtl(I18n.t('esign_consent_disclosure_title', locale:)))), locale
        expect(text).to match(pdf_phrase(rtl(I18n.t('esign_consent_shown_to',
                                                    submitter_name: submitter.name || submitter.email,
                                                    locale:)))), locale
        # The first and the last paragraph of the disclosure, with the sender
        # filled in — the whole text is between them.
        paragraphs = EsignConsent.disclosure_paragraphs(
          EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale:),
          sender_name: 'Acme Ltd', sender_email: admin_for(account).email
        )

        expect(paragraphs.size).to eq(9), locale
        [paragraphs.first, paragraphs.last].each do |paragraph|
          expect(text).to match(pdf_phrase(rtl(paragraph).first(60))), "#{locale}: #{paragraph.first(60)}"
        end

        expect(text).not_to include(ConsentSpecSupport::SENDER_PLACEHOLDER), locale
        expect(text).not_to match(/translation missing/i), locale
        # The one client attestation, named as an attestation. It sits in the
        # signer block beside "Email verification: Verified", which the trail
        # has always drawn in logical order, so it is not bidi-reordered — the
        # appendix above is.
        expect(text).to match(pdf_phrase(I18n.t('esign_consent_pdf_opened', locale:))), locale
        expect(text).not_to match(pdf_phrase(I18n.t('esign_consent_pdf_not_opened', locale:))), locale
      end
    end

    # Direction is a property of the language, not of the characters in the
    # string: an English disclosure that names an Arabic company is still an
    # English sentence and must not come out mirrored.
    it 'keeps an English trail in logical order and reverses only the names inside it' do
      platform_certificate!
      account.update!(locale: 'en', name: 'شركة أكمي')
      submitter = emailed_submitter_for(account)
      submitter.update!(name: 'ישראל ישראלי')

      put "/s/#{submitter.slug}", params: completion_params(submitter).merge(consent_params(submitter, locale: 'en'))

      expect(response).to have_http_status(:ok)

      text = pdf_text(submitter.submission.reload.audit_trail.download)
      paragraphs = EsignConsent.disclosure_paragraphs(
        EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale: 'en'),
        sender_name: rtl(account.name), sender_email: admin_for(account).email
      )

      # English prose, unmirrored, with the Arabic company name reordered.
      expect(text).to match(pdf_phrase(paragraphs.first.first(70)))
      expect(text).to include(rtl(account.name))
      expect(text).not_to include(account.name)
      # The heading too: English, with only the Hebrew signer name reordered.
      expect(text).to match(pdf_phrase(I18n.t('esign_consent_disclosure_title', locale: :en)))
      expect(text).to match(pdf_phrase(I18n.t('esign_consent_shown_to', submitter_name: rtl(submitter.name),
                                                                        locale: :en)))
      # ...and never the other way round: the heading must not carry the signer
      # name in logical order (the event log below still does, as it always has).
      expect(text).not_to match(pdf_phrase(I18n.t('esign_consent_shown_to', submitter_name: submitter.name,
                                                                            locale: :en)))
    end

    it 'prints the consent line in each base locale and never a missing translation' do
      platform_certificate!

      ConsentSpecSupport::BASE_LOCALES.each do |locale|
        account.update!(locale:)
        submitter = emailed_submitter_for(account)

        put "/s/#{submitter.slug}", headers: { 'HTTP_ACCEPT_LANGUAGE' => locale },
                                    params: completion_params(submitter).merge(consent_params(submitter, locale:))

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
