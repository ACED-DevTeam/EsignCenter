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
# versioned consent event carrying the signer's IP exists. The consent line
# is printed in the audit trail in every base locale, and no locale can show
# a missing translation.
#
# Sender-attested completions (API `completed: true`, signing sessions created
# completed) have no human signer: they complete with zero consent events and
# an `api_complete_form` event instead. See docs/esign-consent.md.

module ConsentSpecSupport
  BASE_LOCALES = %w[en es it fr pt de pl uk cs he nl ar ko ja].freeze
  CONSENT_KEYS = %w[esign_consent_checkbox_label esign_consent_disclosure_link esign_consent_disclosure_title
                    esign_consent_disclosure_body_html esign_consent_version_label esign_consent_required
                    consented_to_electronic_signatures close submission_event_names.esign_consent_by_html].freeze
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

  # Link, embed and selfsign submissions copy the template's fields on the
  # first save, so fall back to the template until then.
  def text_field(submitter)
    fields = submitter.submission.template_fields.presence || submitter.submission.template.fields

    fields.find { |f| f['type'] == 'text' && f['submitter_uuid'] == submitter.uuid }
  end

  # The consent always travels with the version the form displayed
  # (consent_version_spec proves a missing or stale version is refused).
  def consent_params
    { esign_consent: 'true', esign_consent_version: EsignConsent::VERSION }
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

  def expect_completed_with_consent(submitter)
    expect(response).to have_http_status(:ok)
    expect(submitter.reload.completed_at).to be_present
    expect(submitter.submission_events.where(event_type: 'complete_form').count).to eq(1)
    expect(consent_events(submitter).count).to eq(1)
    expect(consent_events(submitter).sole.data).to include('version' => 'v1')
    expect(consent_events(submitter).sole.data['ip']).to be_present
  end

  def expect_gated(submitter)
    put "/s/#{submitter.slug}", params: completion_params(submitter)
    expect_consent_refused(submitter)

    put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
    expect_completed_with_consent(submitter)
    expect(ProcessSubmitterCompletionJob.jobs.size).to eq(1)
  end

  def pdf_text(bytes)
    document = HexaPDF::Document.new(io: StringIO.new(bytes))

    document.pages.map do |page|
      collector = ConsentSpecTextCollector.new(page.resources)
      page.process_contents(collector)
      collector.text
    end.join(' ')
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
      expect(consent_events(submitter).sole.data).to include('version' => 'v1')

      travel_to(consented_at + 1.hour) do
        put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
      end

      expect_completed_with_consent(submitter)
      expect(consent_events(submitter).sole.event_timestamp).to eq(consented_at)

      # A completion without the flag still passes once consent is on record.
      put "/s/#{submitter.slug}", params: completion_params(submitter)
      expect(response.parsed_body).to eq('error' => I18n.t('form_has_been_completed_already'))
    end

    it 'exposes the consent version through the API event data' do
      submitter = emailed_submitter_for(paid_account)

      put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')
      expect_completed_with_consent(submitter)

      # The API show endpoint renders the signed result on read, so it signs.
      platform_certificate!

      get "/api/submitters/#{submitter.id}", headers: token_headers(paid_account)

      event = response.parsed_body['submission_events'].find { |e| e['event_type'] == 'esign_consent' }

      expect(event).to be_present
      expect(event['data']).to eq('version' => 'v1')
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
      english = %w[esign_consent_checkbox_label esign_consent_disclosure_body_html].index_with do |key|
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
    it 'prints the consent line in each base locale and never a missing translation' do
      platform_certificate!

      ConsentSpecSupport::BASE_LOCALES.each do |locale|
        account.update!(locale:)
        submitter = emailed_submitter_for(account)

        put "/s/#{submitter.slug}", params: completion_params(submitter, esign_consent: 'true')

        expect(response).to have_http_status(:ok), locale
        expect(submitter.reload.completed_at).to be_present, locale

        audit_trail = submitter.submission.reload.audit_trail

        expect(audit_trail).to be_attached, locale

        text = pdf_text(audit_trail.download)

        expect(text).not_to match(/translation missing/i), "#{locale}: #{text[/.{0,40}translation missing.{0,60}/i]}"
        expect(text).to include(I18n.t('consented_to_electronic_signatures', locale:)), locale
        expect(text).to include("(#{EsignConsent::VERSION})"), locale
      end
    end
  end
end
