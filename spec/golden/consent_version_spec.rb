# frozen_string_literal: true

# A consent is recorded for the disclosure version the signer actually saw:
# the form sends the version it displayed, a different one is refused with a
# reload message, and one submitter never gets two consent events even when
# two requests record at once.
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

  describe 'the signing page' do
    it 'tells the form which version it displays and the reload message for a stale one' do
      get "/s/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('&quot;version&quot;:&quot;v1&quot;')
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('esign_consent_version_stale')))
    end
  end

  describe 'completion with a consent version' do
    it 'refuses a consent for a version other than the current one and records nothing' do
      complete(submitter, esign_consent: 'true', esign_consent_version: 'v0')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'esign_consent_version_stale')
      expect(consent_events(submitter)).not_to exist
      expect(submitter.reload.completed_at).to be_nil
      expect(submitter.submission_events.where(event_type: 'complete_form')).not_to exist
      expect(ProcessSubmitterCompletionJob.jobs).to be_empty
    end

    it 'records the consent with the matching version and completes' do
      complete(submitter, esign_consent: 'true', esign_consent_version: EsignConsent::VERSION)

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.completed_at).to be_present
      expect(consent_events(submitter).sole.data).to include('version' => EsignConsent::VERSION)
    end

    # A page loaded before the version field existed sends no version; it saw
    # the current text, so the consent is recorded for the current version.
    it 'takes a consent without a version as the current version' do
      complete(submitter, esign_consent: 'true')

      expect(response).to have_http_status(:ok)
      expect(consent_events(submitter).sole.data).to include('version' => EsignConsent::VERSION)
    end

    it 'refuses a stale version on the invite request too' do
      post "/s/#{submitter.slug}/invite", params: { esign_consent: 'true', esign_consent_version: 'v0' }

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

      event = EsignConsent.record!(submitter, request, version: EsignConsent::VERSION)

      expect(Submitter).to have_received(:lock)
      expect(event).to eq(first_event)
      expect(consent_events(submitter).count).to eq(1)
    end

    it 'raises before touching the database for a stale version' do
      expect { EsignConsent.record!(submitter, request, version: 'v0') }
        .to raise_error(EsignConsent::StaleVersionError)

      expect(consent_events(submitter)).not_to exist
    end
  end
end
