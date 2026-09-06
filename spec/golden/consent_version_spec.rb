# frozen_string_literal: true

# A consent is recorded for the disclosure version the signer actually saw:
# the form sends the version it displayed, a different one — or none at all —
# is refused with a reload message, and one submitter never gets two consent
# events even when two requests record at once.
#
# Companion to spec/golden/consent_spec.rb (which proves the gate on every
# path); this file proves the version binding and the once-only guarantee.

# The live disclosure, pinned byte for byte. Every consent event on record
# carries one of these fingerprints, and the audit trail reproduces a signer's
# wording only while the text on file still hashes to the digest recorded on
# their event (Submissions::GenerateAuditTrail#consent_wording_recorded?). So
# editing a word of any locale's disclosure without bumping the version does
# not quietly rewrite what old evidence says the signer agreed to — it turns
# this pin RED, and the editor has to do what docs/esign-consent.md §6 asks:
# archive the superseded text of every base locale under
# config/locales/esign_disclosures/<old-version>.yml — the body AND that
# version's three self-signing paragraphs, which are part of the same
# fingerprint — change the wording, bump EsignConsent::VERSION and
# EFFECTIVE_DATE, then recompute the digests below
# (`EsignConsent.disclosure_sha256(version:, locale:, self_signing:)`).
#
# Computed 2026-09-06 from config/locales/i18n.yml for v2 (effective
# 5 September 2026). Two per locale: the disclosure a signer sent a document by
# somebody else reads, and the self-signing variant a sender signing their own
# document reads, which is fingerprinted separately on the event.
module ConsentDisclosureDigests
  VERSION = 'v2'
  LIVE = {
    'en' => { text: 'e8ddd3babdf9e57a6ad35092be37f20444774d524c567b6e6ed85cd3538be549',
              self_signing: '5b5a532c674ef2dc7abd99836339065c9826ee77ae92892b28813daeb02fbc04' },
    'es' => { text: '479e5dc5b4a0bf17c3f59322516fdcf0178af19f07207673ede0ecd51cfcd194',
              self_signing: '20a19fa59ec4003d58c633bb2b7c74f5e55011dc05cd0a9392bcd1f28a1a0347' },
    'fr' => { text: 'd960849349677619b95a4e0fbd26772cdc1a3b5e4f325809cefe6e43664ff6b9',
              self_signing: '5fee9e857fdc31c04a1330fdca75c1ce0cef2b4a117f181c8d4e1242ce8a673f' },
    'pt' => { text: '8bee90241158d96049c80726d88809580bd4c518c90f53a83f4952ec13c2c529',
              self_signing: 'cf47d09f91db379edd7e865e7a556e52f698d7a85a3cf8d1eb839a146bf73135' },
    'de' => { text: 'd3626ad7cb56716210b067fc098c5d49c53da65da4ac9c7e8ac74cd49003d3f1',
              self_signing: '81ac410d553f55830aac763c1434da55121d668e4e9c8a3f533013c4e63bec16' },
    'it' => { text: '20455d6cc287ace687a1cf7e46a1b7286492da69e782c9e967d9150659e602db',
              self_signing: 'cb12a15a443df4492d05c68823523c994a3c53b6156126c350f5b3dc32e72547' },
    'nl' => { text: 'ab88b38c6a7074efedb31aea857c51361a444b6fb299b613d4bcdabcda52993e',
              self_signing: '2107c6960d38cedbc7526531b8e216154f1eb41dd53eed4f47c07845d3a844f3' },
    'pl' => { text: '1a8379fc5b482dc27050387ada29702e399b5864171221611066cd02999904e3',
              self_signing: 'fd001e8df108971d0220348c93efbbc0b67e3cc500e04bf96930f411c9bf92c6' },
    'uk' => { text: '5ba5bc57f266893327a26d6f01b8ae9556ff1f5b44bd44911a1fe45c031f85b9',
              self_signing: '034b5a68422d82c7bf5b8ba4cd0e781bc13f6f3068815ee9fe1fbd0c00b6f480' },
    'cs' => { text: '9798f341196dd51a85f16e7206698b1de08a339044e8e0475d15bc02e9b40389',
              self_signing: 'f36b1dfb927c6ee794859fdcb81fd3fd6d70a0454e24180babd640565582f827' },
    'he' => { text: '47f246f4ac37bf0b9f19413a2292bd0233b8460308edaff0946fc31df3d84a55',
              self_signing: '478ae253f522b97d2f0d43c55f7c30584f58c2a68f80180d24725c1d2b78d4da' },
    'ar' => { text: '42247e56810d00ba7e2d5f8c377d67593f68466b8be15b6077df3ee2be5548ac',
              self_signing: '91d76ef40c1bdd53e515f5229510afdf15701f93d61757c9325e0a51c7de2767' },
    'ko' => { text: '85bfc897b510a293c2427fc2d5193c01597cea8fff1cf1f80a4c3857d57a5bb3',
              self_signing: '91c61a17208994dfdbcb3a3e1fc100bceb596672b86477220a3cae352e9ad541' },
    'ja' => { text: '1bc9765f2f751cea8f3fd596eb3ab87bc8153835376932a6de32a605e9bbc738',
              self_signing: '7140cac7d5c8200d335376a8fe72e1182b0c7c35025f4ce5a049577ff4bd45a1' }
  }.freeze
end

RSpec.describe 'ESIGN consent version', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account:) }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: admin) }
  let(:submitter) do
    submission.submitters.first.tap { |s| s.update!(sent_at: Time.current, email: 'signer@example.com') }
  end
  let(:text_field) { template.fields.find { |f| f['type'] == 'text' } }

  def consent_events(submitter)
    submitter.submission_events.where(event_type: 'esign_consent')
  end

  def complete(submitter, headers: {}, **consent)
    put "/s/#{submitter.slug}", headers:,
                                params: { completed: 'true', values: { text_field['uuid'] => 'Jane' }, **consent }
  end

  # Everything a current page sends back with the consent, the signed locale
  # pair included — an interactive consent without it is refused (below).
  def current_consent(submitter, locale: EsignConsent.rendered_locale)
    { esign_consent: 'true', esign_consent_version: EsignConsent::VERSION,
      esign_consent_locale: locale,
      esign_consent_locale_token: EsignConsent.locale_token(submitter, locale),
      esign_consent_sender_digest: EsignConsent.sender_digest(submitter) }
  end

  # A consent with the version and the sender fingerprint but nothing about
  # the language — what a page that dropped the pair would send.
  def without_locale_pair(submitter)
    current_consent(submitter).except(:esign_consent_locale, :esign_consent_locale_token)
  end

  describe 'the signing page' do
    it 'tells the form which version it displays and the reload message for a stale one' do
      get "/s/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("&quot;version&quot;:&quot;#{EsignConsent::VERSION}&quot;")
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('esign_consent_version_stale')))
    end
  end

  describe 'completion with a consent version' do
    # G13 + F6: the version must be present AND current. A request with no
    # version at all is stale too — nothing vouches for which text that page
    # showed, so the signer reloads and agrees again. Both refusals happen
    # before any write, so both cases assert the same empty aftermath.
    # `v1` is the archived launch disclosure (config/locales/esign_disclosures):
    # its text is still readable, but a consent given on it is no longer current.
    [['for a version other than the current one', { esign_consent_version: 'v0' }],
     ['for the superseded v1 disclosure', { esign_consent_version: 'v1' }],
     ['without a version at all', {}]].each do |description, version_params|
      it "refuses a consent #{description} as stale and records nothing" do
        complete(submitter, esign_consent: 'true', **version_params)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq('error' => 'esign_consent_version_stale')
        expect(consent_events(submitter)).not_to exist
        expect(submitter.reload.completed_at).to be_nil
        expect(submitter.submission_events.where(event_type: 'complete_form')).not_to exist
        expect(ProcessSubmitterCompletionJob.jobs).to be_empty
      end
    end

    it 'records the consent with the matching version and completes' do
      complete(submitter, **current_consent(submitter))

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.completed_at).to be_present
      expect(consent_events(submitter).sole.data).to include('version' => EsignConsent::VERSION)
    end
  end

  # D77 A review: the recorded sender must be the sender the page showed. The
  # form sends a fingerprint of the name and address it rendered; the server
  # recomputes it and refuses on a mismatch, exactly as it refuses a stale
  # version — otherwise a rename while the modal sat open would file one
  # sender against a disclosure that named another.
  describe 'the sender the page displayed' do
    it 'refuses a consent whose sender no longer matches, and takes it after a reload' do
      stale = current_consent(submitter)

      account.update!(name: 'Renamed Mid-Signing Ltd')

      complete(submitter, **stale)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_version_stale')
      expect(consent_events(submitter)).not_to exist
      expect(submitter.reload.completed_at).to be_nil

      # The reload shows the new name, and the consent given on it is taken.
      get "/s/#{submitter.slug}"
      expect(response.body).to include('Renamed Mid-Signing Ltd')

      complete(submitter, **current_consent(submitter.reload))

      expect(response).to have_http_status(:ok)
      expect(consent_events(submitter).sole.data)
        .to include('sender_name' => 'Renamed Mid-Signing Ltd',
                    'sender_email' => EsignConsent.sender_email(submitter))
    end

    it 'refuses a consent that carries no sender fingerprint at all' do
      complete(submitter, esign_consent: 'true', esign_consent_version: EsignConsent::VERSION)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_version_stale')
      expect(consent_events(submitter)).not_to exist
    end

    it 'puts the fingerprint on the signing page for the form to send back' do
      get "/s/#{submitter.slug}"

      expect(response.body).to include(EsignConsent.sender_digest(submitter))
    end

    it 'refuses a stale version on the invite request too' do
      post "/s/#{submitter.slug}/invite",
           params: { esign_consent: 'true', esign_consent_version: 'v0',
                     esign_consent_sender_digest: EsignConsent.sender_digest(submitter) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_version_stale')
      expect(consent_events(submitter)).not_to exist
    end
  end

  # B3: the record must fingerprint the disclosure the page put in front of
  # this signer. The completion request cannot answer that — its own locale is
  # client-controlled twice over (`?lang=` and Accept-Language) — so the page
  # that did the rendering signs its answer and the form hands it back. The
  # token is what picks the text; the posted locale alone never does.
  #
  # Every refusal below answers `esign_consent_locale_invalid`, not
  # `esign_consent_version_stale`: nothing about the disclosure was updated,
  # and a product that tells a signer otherwise is lying in the one place it
  # cannot afford to.
  describe 'the locale the page rendered the disclosure in' do
    let(:french) { { 'HTTP_ACCEPT_LANGUAGE' => 'fr-FR,fr;q=0.9' } }

    def digest_for(locale)
      EsignConsent.disclosure_sha256(version: EsignConsent::VERSION, locale:)
    end

    # The locale AND the token the signing page itself issued, read straight
    # off the page the way a browser would, never recomputed here.
    def issued_by_page(browser = {})
      get "/s/#{submitter.slug}", headers: browser

      config = JSON.parse(Nokogiri::HTML(response.body).at_css('submission-form')['data-esign-consent'])

      { esign_consent_locale: config.fetch('locale'),
        esign_consent_locale_token: config.fetch('locale_token') }
    end

    it 'refuses a consent naming a locale the page did not render in, and records nothing' do
      issued = issued_by_page(french)

      expect(issued[:esign_consent_locale]).to eq('fr')
      expect(issued[:esign_consent_locale_token]).to match(/\A\h{64}\z/)

      complete(submitter, headers: french, **current_consent(submitter),
                          **issued.merge(esign_consent_locale: 'ar'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_locale_invalid')
      expect(consent_events(submitter)).not_to exist
      expect(submitter.reload.completed_at).to be_nil
      expect(ProcessSubmitterCompletionJob.jobs).to be_empty
    end

    # Codex loop-2 #2: `lang` is a request parameter, so a signer who could
    # steer the completion's own locale would have steered the record with it.
    # The token is the English page's, and it is the token that decides.
    it 'refuses an English page a consent claiming another language, `lang` and all' do
      issued = issued_by_page

      expect(issued[:esign_consent_locale]).to eq('en')

      put "/s/#{submitter.slug}?lang=ar",
          params: { completed: 'true', values: { text_field['uuid'] => 'Jane' },
                    **current_consent(submitter), **issued.merge(esign_consent_locale: 'ar') }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_locale_invalid')
      expect(consent_events(submitter)).not_to exist
      expect(submitter.reload.completed_at).to be_nil
      expect(ProcessSubmitterCompletionJob.jobs).to be_empty
    end

    it 'refuses a consent whose locale token is forged, and one that carries no token at all' do
      issued = issued_by_page(french)

      complete(submitter, headers: french, **current_consent(submitter),
                          **issued.merge(esign_consent_locale_token: 'f' * 64))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_locale_invalid')
      expect(consent_events(submitter)).not_to exist

      complete(submitter, headers: french, **current_consent(submitter),
                          esign_consent_locale: 'fr', esign_consent_locale_token: nil)

      expect(response).to have_http_status(:unprocessable_content)
      expect(consent_events(submitter)).not_to exist
      expect(submitter.reload.completed_at).to be_nil
    end

    it 'refuses a token issued to another signer' do
      other = create(:submission, :with_submitters, template:, created_by_user: admin).submitters.first

      expect(other.slug).not_to eq(submitter.slug)

      complete(submitter, **current_consent(submitter),
                          esign_consent_locale: 'en',
                          esign_consent_locale_token: EsignConsent.locale_token(other, 'en'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(consent_events(submitter)).not_to exist
    end

    it 'records the digest of the disclosure the page really rendered' do
      complete(submitter, headers: french, **current_consent(submitter), **issued_by_page(french))

      expect(response).to have_http_status(:ok)
      expect(consent_events(submitter).sole.data)
        .to include('locale' => 'fr', 'disclosure_sha256' => digest_for('fr'))
      expect(digest_for('fr')).not_to eq(digest_for('en'))
    end

    # Codex loop-2 #1: the honest `/s/:slug?lang=fr` link. The form posts to a
    # bare `/s/:slug`, so the completion resolves English however the signer's
    # browser is set — and the French page's token still files French.
    it 'records the locale the page rendered even when the completion request resolves another' do
      issued = issued_by_page(french)

      expect(issued[:esign_consent_locale]).to eq('fr')

      complete(submitter, headers: { 'HTTP_ACCEPT_LANGUAGE' => 'en-US,en;q=0.9' },
                          **current_consent(submitter), **issued)

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.completed_at).to be_present
      expect(consent_events(submitter).sole.data)
        .to include('locale' => 'fr', 'disclosure_sha256' => digest_for('fr'))
    end

    it 'refuses a posted locale this product does not speak, which nothing can vouch for' do
      expect(EsignConsent.locale_token(submitter, 'zz-ZZ nonsense')).to be_nil

      complete(submitter, **current_consent(submitter),
                          esign_consent_locale: 'zz-ZZ nonsense',
                          esign_consent_locale_token: EsignConsent.locale_token(submitter, 'en'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_locale_invalid')
      expect(consent_events(submitter)).not_to exist
      expect(submitter.reload.completed_at).to be_nil
    end

    # S10 D2, the hole review 9 left open: the pair was only checked when it
    # was SENT. Omit it and record! fell through to `rendered_locale`, which is
    # the completion request's own locale — the value the client chooses with
    # `?lang=` and Accept-Language. So the whole token could simply be dropped
    # and the language steered anyway. Both interactive callers now require it.
    [['omits the locale and its token entirely', {}],
     ['sends a blank locale', { esign_consent_locale: '', esign_consent_locale_token: '' }],
     ['sends a locale with no token', { esign_consent_locale: 'ar' }]].each do |description, claim|
      it "refuses a consent that #{description}, whatever `lang` the request carries" do
        put "/s/#{submitter.slug}?lang=ar",
            headers: french,
            params: { completed: 'true', values: { text_field['uuid'] => 'Jane' },
                      **without_locale_pair(submitter), **claim }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq('error' => 'esign_consent_locale_invalid')
        expect(consent_events(submitter)).not_to exist
        expect(submitter.reload.completed_at).to be_nil
        expect(ProcessSubmitterCompletionJob.jobs).to be_empty
      end

      it "refuses the invite request that #{description} too" do
        submitter.update!(values: { text_field['uuid'] => 'Jane' })

        post "/s/#{submitter.slug}/invite?lang=ar", headers: french,
                                                    params: { **without_locale_pair(submitter), **claim }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq('error' => 'esign_consent_locale_invalid')
        expect(consent_events(submitter)).not_to exist
        expect(submitter.reload.completed_at).to be_nil
      end
    end

    # The message the refusal shows is its own, and says what happened.
    it 'gives the locale refusal a message of its own in all 14 locales' do
      expect(I18n.t('esign_consent_locale_invalid')).not_to eq(I18n.t('esign_consent_version_stale'))

      EsignConsent.locales.each do |locale|
        message = I18n.t('esign_consent_locale_invalid', locale:, fallback: false, raise: true)

        expect(message).to be_present, locale
        expect(message).not_to eq(I18n.t('esign_consent_locale_invalid', locale: :en)) unless locale == 'en'
      end

      get "/s/#{submitter.slug}"

      expect(response.body).to include(ERB::Util.html_escape(I18n.t('esign_consent_locale_invalid')))
    end

    it 'resolves the same locale on the invite request as the signing page did' do
      submitter.update!(values: { text_field['uuid'] => 'Jane' })

      issued = issued_by_page(french)

      post "/s/#{submitter.slug}/invite", headers: french,
                                          params: { esign_consent: 'true',
                                                    esign_consent_version: EsignConsent::VERSION,
                                                    **issued,
                                                    esign_consent_sender_digest: EsignConsent.sender_digest(submitter) }

      expect(response).to have_http_status(:ok)
      expect(consent_events(submitter).sole.data)
        .to include('locale' => 'fr', 'disclosure_sha256' => digest_for('fr'))
    end

    it 'refuses the invite request a locale the page never issued a token for' do
      submitter.update!(values: { text_field['uuid'] => 'Jane' })

      post "/s/#{submitter.slug}/invite", headers: french,
                                          params: { esign_consent: 'true',
                                                    esign_consent_version: EsignConsent::VERSION,
                                                    esign_consent_locale: 'ar',
                                                    esign_consent_locale_token:
                                                      EsignConsent.locale_token(submitter, 'fr'),
                                                    esign_consent_sender_digest: EsignConsent.sender_digest(submitter) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_locale_invalid')
      expect(consent_events(submitter)).not_to exist
    end
  end

  describe 'EsignConsent.record! under concurrency' do
    let(:request) do
      instance_double(ActionDispatch::Request, remote_ip: '203.0.113.9', user_agent: 'RSpec',
                                               session: instance_double(ActionDispatch::Request::Session, id: 'sid'),
                                               env: { 'warden' => instance_double(Warden::Proxy, user: nil) })
    end

    it 'returns the event another request inserted while this one waited for the row lock' do
      first_event = nil

      # The concurrent request lands between this call's start and its lock.
      allow(Submitter).to receive(:lock).and_wrap_original do |original, *args|
        first_event ||= SubmissionEvents.create_with_tracking_data(submitter, 'esign_consent', request,
                                                                   { version: EsignConsent::VERSION })

        original.call(*args)
      end

      event = EsignConsent.record!(submitter, request, version: EsignConsent::VERSION,
                                                       sender_digest: EsignConsent.sender_digest(submitter))

      expect(Submitter).to have_received(:lock)
      expect(event).to eq(first_event)
      expect(consent_events(submitter).count).to eq(1)
    end

    it 'raises before touching the database for a stale version or sender' do
      digest = EsignConsent.sender_digest(submitter)

      expect { EsignConsent.record!(submitter, request, version: 'v0', sender_digest: digest) }
        .to raise_error(EsignConsent::StaleVersionError)
      expect { EsignConsent.record!(submitter, request, version: nil, sender_digest: digest) }
        .to raise_error(EsignConsent::StaleVersionError)
      expect { EsignConsent.record!(submitter, request) }
        .to raise_error(EsignConsent::StaleVersionError)
      expect { EsignConsent.record!(submitter, request, version: EsignConsent::VERSION, sender_digest: 'nope') }
        .to raise_error(EsignConsent::StaleVersionError)

      expect(consent_events(submitter)).not_to exist
    end

    it 'refuses a locale no token of ours vouches for, and takes one that is signed' do
      digest = EsignConsent.sender_digest(submitter)

      # A locale with no token, a locale carrying another locale's token, and
      # one this product does not speak (no disclosure, so no token exists).
      [{ locale: 'ar' },
       { locale: 'ar', locale_token: EsignConsent.locale_token(submitter, 'en') },
       { locale: 'not-a-locale', locale_token: EsignConsent.locale_token(submitter, 'en') }].each do |claim|
        expect do
          EsignConsent.record!(submitter, request, version: EsignConsent::VERSION, sender_digest: digest, **claim)
        end.to raise_error(EsignConsent::LocaleInvalidError), claim.inspect
        expect(consent_events(submitter)).not_to exist, claim.inspect
      end

      event = EsignConsent.record!(submitter, request, version: EsignConsent::VERSION, sender_digest: digest,
                                                       locale: 'ar',
                                                       locale_token: EsignConsent.locale_token(submitter, 'ar'))

      # The signed locale, not the locale this request happens to render in.
      expect(event.data).to include('locale' => 'ar')
      expect(EsignConsent.rendered_locale).not_to eq('ar')
    end

    # A caller with no page behind it (record! straight from the server) has no
    # token to offer and stands on the server's own answer, exactly as before.
    # That path is the default and is reachable only from Ruby: the two
    # interactive callers pass `require_locale:` and are refused without it.
    it 'stands on the request locale when no locale is posted at all' do
      event = EsignConsent.record!(submitter, request, version: EsignConsent::VERSION,
                                                       sender_digest: EsignConsent.sender_digest(submitter))

      expect(event.data).to include('locale' => EsignConsent.rendered_locale)
      expect(event.data).not_to have_key('pdf_opened')
    end

    it 'refuses the same call once the caller says it came from a page' do
      expect do
        EsignConsent.record!(submitter, request, version: EsignConsent::VERSION,
                                                 sender_digest: EsignConsent.sender_digest(submitter),
                                                 require_locale: true)
      end.to raise_error(EsignConsent::LocaleInvalidError, 'esign_consent_locale_invalid')

      expect(consent_events(submitter)).not_to exist
    end
  end

  # B-F4's CI guard: see ConsentDisclosureDigests above.
  describe 'the live disclosure fingerprints' do
    it 'still hashes to the pinned v2 digests in every base locale' do
      expect(EsignConsent::VERSION).to eq(ConsentDisclosureDigests::VERSION),
                                       'the version was bumped: re-pin ConsentDisclosureDigests::LIVE'
      expect(EsignConsent.locales).to match_array(ConsentDisclosureDigests::LIVE.keys)

      ConsentDisclosureDigests::LIVE.each do |locale, digests|
        expect(EsignConsent.disclosure_sha256(version: EsignConsent::VERSION, locale:))
          .to eq(digests.fetch(:text)), locale
        expect(EsignConsent.disclosure_sha256(version: EsignConsent::VERSION, locale:, self_signing: true))
          .to eq(digests.fetch(:self_signing)), "#{locale} (self-signing)"
      end
    end
  end

  # A3: the self-signing paragraphs (EsignConsent::SELF_SIGNING_KEYS) are part
  # of the fingerprinted text — a "sign it yourself" signer's
  # `disclosure_sha256` is of the body WITH them spliced in — so they sit under
  # the version rule with the bodies, not outside it. They used to be read from
  # the live locale file for every version, which meant one later edit of a
  # self-signing paragraph rewrote what every self-signing consent ever
  # recorded says it was, under every version, and the audit trail could only
  # answer "wording no longer on file" for those signers.
  #
  # Now a version's words come from ONE place: the live keys while it is
  # current, its archive snapshot once it is superseded.
  describe 'the self-signing paragraphs under the version rule' do
    # A "sign it yourself" signer: the sender's own login is the signer's email.
    let(:self_signer) do
      create(:submission, :with_submitters, template:, created_by_user: admin)
        .submitters.first.tap { |s| s.update!(sent_at: Time.current, email: admin.email) }
    end

    # The live paragraphs as this run found them, read BEFORE any example can
    # edit them and put back afterwards, so the pinned digests above are never
    # left rewritten for the rest of the suite.
    let(:live_self_signing) do
      EsignConsent.locales.index_with do |locale|
        EsignConsent::SELF_SIGNING_KEYS.index_with { |key| I18n.t(key, locale:, fallback: false) }
      end
    end

    # What docs/esign-consent.md §6 tells an editor to write into
    # config/locales/esign_disclosures/<version>.yml, done in memory: the
    # version's body AND its three self-signing paragraphs, taken
    # programmatically so the bytes archived are the bytes published.
    def archive!(version, locales)
      locales.each do |locale|
        I18n.backend.store_translations(
          locale.to_sym,
          esign_disclosure_archive: {
            version => I18n.t(EsignConsent::DISCLOSURE_KEY, locale:, fallback: false),
            "#{version}#{EsignConsent::SELF_SIGNING_ARCHIVE_SUFFIX}" =>
              EsignConsent::SELF_SIGNING_KEYS.index_with { |key| I18n.t(key, locale:, fallback: false) }
          }
        )
      end
    end

    # Translations loaded from the locale files are frozen; a scope this
    # example wrote to is not, because store_translations merges it into a new
    # hash. So a frozen scope is one nothing was stored into — nothing to undo.
    def unarchive!(version, locales)
      locales.each do |locale|
        scope = I18n.backend.translations[locale.to_sym][:esign_disclosure_archive]

        next if scope.nil? || scope.frozen?

        scope.delete(version.to_sym)
        scope.delete(:"#{version}#{EsignConsent::SELF_SIGNING_ARCHIVE_SUFFIX}")
      end
    end

    before { live_self_signing }

    after do
      live_self_signing.each { |locale, keys| I18n.backend.store_translations(locale.to_sym, keys) }
      unarchive!('v2', EsignConsent.locales)
    end

    # (b) The resolver and the fingerprint are the same text by construction:
    # hashing what `disclosure_text` returns, with the one shared function the
    # audit trail uses, reproduces exactly the digest stamped on the event.
    it 'reproduces the very bytes each pinned fingerprint was computed over' do
      ConsentDisclosureDigests::LIVE.each do |locale, digests|
        plain = EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale:)
        variant = EsignConsent.disclosure_text(version: EsignConsent::VERSION, locale:, self_signing: true)

        expect(EsignConsent.text_sha256(plain)).to eq(digests.fetch(:text)), locale
        expect(EsignConsent.text_sha256(variant)).to eq(digests.fetch(:self_signing)), "#{locale} (self-signing)"
      end
    end

    # (1) A consent recorded against the CURRENT version resolves its text from
    # the live locale keys, and the audit trail's own check passes on it.
    it 'resolves a current-version self-signing consent from the live keys' do
      complete(self_signer, **current_consent(self_signer))

      expect(response).to have_http_status(:ok)

      event = consent_events(self_signer).sole
      locale = event.data.fetch('locale')

      expect(event.data).to include('version' => EsignConsent::VERSION, 'self_signing' => true)

      text = EsignConsent.disclosure_text(version: event.data['version'], locale:,
                                          self_signing: event.data['self_signing'])

      EsignConsent::SELF_SIGNING_KEYS.each { |key| expect(text).to include(I18n.t(key, locale:)), key }

      # Submissions::GenerateAuditTrail#consent_wording_recorded?, in one line.
      expect(EsignConsent.text_sha256(text)).to eq(event.data['disclosure_sha256'])
      expect(event.data['disclosure_sha256'])
        .to eq(ConsentDisclosureDigests::LIVE.fetch(locale).fetch(:self_signing))
    end

    # (2) The bump this whole rule exists for. v2 is archived (body and
    # paragraphs together), VERSION moves to v3, and v3 rewrites a self-signing
    # paragraph. The v2 event's words — and its fingerprint — must not move.
    it 'keeps an old self-signing consent readable after a bump that rewrites the live paragraphs' do
      complete(self_signer, **current_consent(self_signer))

      expect(response).to have_http_status(:ok)

      event = consent_events(self_signer).sole
      as_signed = EsignConsent.disclosure_text(version: 'v2', locale: event.data['locale'], self_signing: true)

      archive!('v2', EsignConsent.locales)
      stub_const('EsignConsent::VERSION', 'v3')

      EsignConsent.locales.each do |locale|
        I18n.backend.store_translations(locale.to_sym,
                                        esign_consent_disclosure_self_signing: "Rewritten for v3 (#{locale}).")
      end

      text = EsignConsent.disclosure_text(version: event.data['version'], locale: event.data['locale'],
                                          self_signing: event.data['self_signing'])

      expect(text).to eq(as_signed)
      expect(text).not_to include('Rewritten for v3')
      expect(EsignConsent.text_sha256(text)).to eq(event.data['disclosure_sha256'])

      ConsentDisclosureDigests::LIVE.each do |locale, digests|
        # Every locale's v2 self-signing text still hashes to what it hashed to
        # before the bump — the digest on record for those signers.
        expect(EsignConsent.disclosure_sha256(version: 'v2', locale:, self_signing: true))
          .to eq(digests.fetch(:self_signing)), locale
        expect(EsignConsent.disclosure_text(version: 'v2', locale:, self_signing: true))
          .not_to include('Rewritten for v3'), locale

        # And the edit really did land: v3 is a different text, as it should be.
        expect(EsignConsent.disclosure_text(version: 'v3', locale:, self_signing: true))
          .to include("Rewritten for v3 (#{locale}).")
        expect(EsignConsent.disclosure_sha256(version: 'v3', locale:, self_signing: true))
          .not_to eq(digests.fetch(:self_signing)), "#{locale} (v3)"
      end
    end

    # v1 shipped before the variant existed, so no v1 consent can carry
    # `self_signing`. The archive says that in as many words rather than
    # leaving a reader to guess whether somebody forgot to archive it — and the
    # resolver refuses to invent the paragraphs either way.
    it 'says v1 never had a self-signing variant, and produces no wording for one' do
      EsignConsent.locales.each do |locale|
        expect(I18n.t("#{EsignConsent::ARCHIVE_SCOPE}.v1#{EsignConsent::SELF_SIGNING_ARCHIVE_SUFFIX}",
                      locale:, fallback: false, raise: true))
          .to eq(EsignConsent::SELF_SIGNING_NEVER_PUBLISHED), locale

        expect(EsignConsent.disclosure_text(version: 'v1', locale:, self_signing: true)).to be_nil, locale
        expect(EsignConsent.disclosure_sha256(version: 'v1', locale:, self_signing: true)).to be_nil, locale

        # The v1 body itself is untouched by any of this and still reads back.
        expect(EsignConsent.disclosure_text(version: 'v1', locale:)).to be_present, locale
      end
    end

    # A snapshot that is missing, or there but half-written, is not a text
    # anybody can vouch for: the trail says "wording no longer on file" rather
    # than splicing today's paragraphs into an old body.
    it 'produces nothing for a version whose self-signing snapshot is missing or incomplete' do
      body = "<p>old #{EsignConsent::SENDER_EMAIL_PLACEHOLDER}</p>"

      I18n.backend.store_translations(:en, esign_disclosure_archive: { v0: body })

      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en')).to eq(body)
      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en', self_signing: true)).to be_nil

      I18n.backend.store_translations(
        :en, esign_disclosure_archive: { v0_self_signing: { EsignConsent::SELF_SIGNING_KEYS.first => 'Only one.' } }
      )

      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en', self_signing: true)).to be_nil

      I18n.backend.store_translations(
        :en,
        esign_disclosure_archive: {
          v0_self_signing: EsignConsent::SELF_SIGNING_KEYS.index_with { |key| "#{key} para" }
        }
      )

      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en', self_signing: true))
        .to eq(EsignConsent::SELF_SIGNING_KEYS.map { |key| "<p>#{key} para</p>" }.join)
    ensure
      unarchive!('v0', ['en'])
      expect(EsignConsent.disclosure_text(version: 'v0', locale: 'en')).to be_nil
    end
  end

  # The bump procedure (docs/esign-consent.md §6) says to archive a superseded
  # version's TWO halves together — the body and the self-signing paragraphs —
  # and until now nothing checked that it had been done. A `v2.yml` written
  # with the body and without `v2_self_signing` passed the whole suite; the
  # omission surfaced later, in production, as "wording no longer on file" on a
  # self-signing signer's audit trail, for consents already on record that
  # cannot be re-taken (review 10, Q7). This is the guard that catches a
  # half-written archive on the day it is committed, in every locale.
  describe 'the archived versions on file' do
    # Read from the files rather than from a list somebody has to remember to
    # extend, so a new `v3.yml` is guarded the day it lands. `_self_signing`
    # keys fold into the version they belong to.
    def archived_versions
      keys = Rails.root.glob('config/locales/esign_disclosures/*.yml').flat_map do |path|
        YAML.safe_load_file(path, aliases: true).values.flat_map do |translations|
          (translations[EsignConsent::ARCHIVE_SCOPE] || {}).keys
        end
      end

      keys.map { |key| key.delete_suffix(EsignConsent::SELF_SIGNING_ARCHIVE_SUFFIX) }.uniq.sort
    end

    def archived(version, locale, suffix: nil)
      I18n.t("#{EsignConsent::ARCHIVE_SCOPE}.#{version}#{suffix}", locale:, fallback: false, default: nil)
    end

    it 'carries a body AND a self-signing answer for every version in every locale' do
      versions = archived_versions

      # The walk has to be real: v1 is on file today, and so are all 14 base
      # locales the disclosure ships in.
      expect(versions).to include('v1')
      expect(EsignConsent.locales.size).to be >= 14

      versions.each do |version|
        EsignConsent.locales.each do |locale|
          expect(archived(version, locale)).to be_present,
                                               "#{locale}: #{EsignConsent::ARCHIVE_SCOPE}.#{version} is missing — " \
                                               'every consent recorded under that version reads back as ' \
                                               '"wording no longer on file"'

          snapshot = archived(version, locale, suffix: EsignConsent::SELF_SIGNING_ARCHIVE_SUFFIX)

          # `never_published` is a fact on the record (v1 shipped before the
          # variant existed); a snapshot is the three paragraphs, all of them.
          if snapshot == EsignConsent::SELF_SIGNING_NEVER_PUBLISHED
            expect(EsignConsent.disclosure_text(version:, locale:, self_signing: true)).to be_nil, locale.to_s
            next
          end

          expect(snapshot).to be_a(Hash),
                              "#{locale}: #{version}#{EsignConsent::SELF_SIGNING_ARCHIVE_SUFFIX} is neither " \
                              "'#{EsignConsent::SELF_SIGNING_NEVER_PUBLISHED}' nor a snapshot of the three " \
                              'self-signing paragraphs — archive both halves together (docs/esign-consent.md §6)'
          expect(snapshot.keys.map(&:to_s)).to include(*EsignConsent::SELF_SIGNING_KEYS), "#{locale} (#{version})"

          # And the resolver really can produce it, which is the promise the
          # archive exists to keep.
          expect(EsignConsent.disclosure_text(version:, locale:, self_signing: true))
            .to be_present, "#{locale} (#{version})"
        end
      end
    end
  end
end
