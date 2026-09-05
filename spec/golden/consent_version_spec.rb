# frozen_string_literal: true

# A consent is recorded for the disclosure version the signer actually saw:
# the form sends the version it displayed, a different one — or none at all —
# is refused with a reload message, and one submitter never gets two consent
# events even when two requests record at once.
#
# Companion to spec/golden/consent_spec.rb (which proves the gate on every
# path); this file proves the version binding and the once-only guarantee.
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

  def complete(submitter, **consent)
    put "/s/#{submitter.slug}", params: { completed: 'true', values: { text_field['uuid'] => 'Jane' }, **consent }
  end

  # Everything a current page sends back with the consent.
  def current_consent(submitter)
    { esign_consent: 'true', esign_consent_version: EsignConsent::VERSION,
      esign_consent_sender_digest: EsignConsent.sender_digest(submitter) }
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
  end
end
