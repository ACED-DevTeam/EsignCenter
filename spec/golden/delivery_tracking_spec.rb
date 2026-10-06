# frozen_string_literal: true

RSpec.describe 'Postmark delivery tracking', type: :request do
  stash_env 'POSTMARK_WEBHOOK_USERNAME', 'POSTMARK_WEBHOOK_PASSWORD', 'POSTMARK_WEBHOOK_IPS'

  let(:account) { create(:account) }
  let(:admin) { create(:user, account:) }
  let(:template) { create(:template, account:, author: admin) }
  let(:submitter) do
    create(:submission, :with_submitters, template:, created_by_user: admin).submitters.first.tap do |signer|
      signer.update!(email: 'signer@example.com')
    end
  end
  let!(:send_event) do
    create(:email_event, account:, emailable: submitter, event_type: 'send', email: 'signer@example.com')
  end
  let(:timeline_projection) do
    { 'permanent_bounce' => 'bounce_email', 'complaint' => 'complaint_email', 'open' => 'open_email' }
  end
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'REMOTE_ADDR' => '192.0.2.10',
      'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials('postmark', 'secret') }
  end

  before do
    ENV['POSTMARK_WEBHOOK_USERNAME'] = 'postmark'
    ENV['POSTMARK_WEBHOOK_PASSWORD'] = 'secret'
    ENV['POSTMARK_WEBHOOK_IPS'] = '192.0.2.0/24'
  end

  def payload(name)
    JSON.parse(Rails.root.join("spec/fixtures/postmark/#{name}.json").read).tap do |record|
      record['Metadata']['message-uuid'] = send_event.message_id
    end
  end

  def deliver(record, request_headers = headers)
    post postmark_webhooks_path, params: record.to_json, headers: request_headers
  end

  %w[POSTMARK_WEBHOOK_USERNAME POSTMARK_WEBHOOK_PASSWORD].each do |key|
    it "refuses unconfigured #{key} before authentication" do
      ENV.delete(key)

      expect { deliver(payload('delivery'), headers.except('HTTP_AUTHORIZATION')) }
        .not_to change(EmailEvent, :count)
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq('error' => 'Postmark webhook is not configured')
    end
  end

  it 'refuses missing or incorrect Basic credentials before checking the IP' do
    [nil, ActionController::HttpAuthentication::Basic.encode_credentials('wrong', 'secret'),
     ActionController::HttpAuthentication::Basic.encode_credentials('postmark', 'wrong')].each do |auth|
      expect do
        deliver(payload('delivery'), headers.merge('HTTP_AUTHORIZATION' => auth, 'REMOTE_ADDR' => '203.0.113.1'))
      end
        .not_to change(EmailEvent, :count)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'refuses an IP outside the configured range' do
    expect { deliver(payload('delivery'), headers.merge('REMOTE_ADDR' => '203.0.113.1')) }
      .not_to change(EmailEvent, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it 'uses the built-in Postmark IPs when the override is blank' do
    ENV['POSTMARK_WEBHOOK_IPS'] = ''
    deliver(payload('delivery'))
    expect(response).to have_http_status(:forbidden)

    deliver(payload('delivery'), headers.merge('REMOTE_ADDR' => '3.134.147.250'))
    expect(response).to have_http_status(:ok)
  end

  it 'rejects malformed JSON and non-record JSON without writing' do
    ['{', '[]', 'null'].each do |body|
      expect { post postmark_webhooks_path, params: body, headers: }.not_to change(EmailEvent, :count)
      expect(response).to have_http_status(:bad_request)
    end
  end

  it 'requires a JSON content type' do
    deliver(payload('delivery'), headers.merge('CONTENT_TYPE' => 'text/plain'))

    expect(response).to have_http_status(:unsupported_media_type)
  end

  { 'delivery' => 'delivery', 'bounce_hard' => 'permanent_bounce', 'bounce_soft' => 'soft_bounce',
    'spam_complaint' => 'complaint', 'open' => 'open', 'click' => 'click',
    'subscription_change' => 'subscription_change' }.each do |fixture, type|
    it "records #{fixture} with our attribution and bounded provider data" do
      record = payload(fixture)
      record['Tag'] = 'untrusted-provider-tag'
      record['Details'] = 'x' * 800
      allow(SendingPause).to receive(:evaluate!)

      expect { deliver(record) }.to change(EmailEvent, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('recorded' => true)

      event = EmailEvent.order(:id).last

      expect(event).to have_attributes(event_type: type, email: 'signer@example.com', account:,
                                       emailable: submitter, message_id: send_event.message_id, tag: send_event.tag)
      expect(event.event_datetime).to be_within(1.second).of(Time.iso8601('2026-09-04T16:33:54.9070259Z'))
      expect(event.provider_event_key).to eq(
        "#{record['RecordType']}:#{record['ID'] || record['MessageID']}:signer@example.com:" \
        '2026-09-04T16:33:54.9070259Z'
      )
      expect(event.data).to include('provider_message_id' => record['MessageID'],
                                    'record_type' => record['RecordType'], 'message_stream' => 'outbound',
                                    'details' => 'x' * 500)
      expect(event.data.keys).not_to include('Content', 'content', 'Metadata', 'metadata', 'Tag', 'tag')
      record.slice('Type', 'TypeCode', 'Description', 'ServerID', 'Inactive', 'OriginalLink',
                   'FirstOpen', 'UserAgent', 'SuppressSending').each do |key, value|
        expect(event.data[key.underscore]).to eq(value)
      end
      expect(event.data['geo']).to eq(record['Geo']) if record['Geo']

      projection = timeline_projection[type]
      events = submitter.submission.submission_events

      if projection
        expect(events.sole).to have_attributes(event_type: projection, submitter:,
                                               event_timestamp: event.event_datetime)
        expect(events.sole.data).to include('email' => event.email)
      else
        expect(events).to be_empty
      end
    end
  end

  it 'deduplicates retries without evaluating a pause or projecting a second timeline row' do
    allow(SendingPause).to receive(:evaluate!)
    record = payload('bounce_hard')
    deliver(record)

    expect { deliver(record) }.not_to change(EmailEvent, :count)
    expect(response.parsed_body).to eq('duplicate' => true)
    expect(submitter.submission.submission_events.count).to eq(1)
    expect(SendingPause).to have_received(:evaluate!).once
  end

  # A message uuid we have never issued a send row for is PARKED rather than
  # ignored now (review 8, D8) — that case has its own examples below. What is
  # still ignored is a callback this application can never attribute at all:
  # an event type we do not record, and a payload with no message uuid on it
  # (Postmark's own webhook verification ping).
  it 'ignores unknown types and absent metadata' do
    [payload('delivery').merge('RecordType' => 'FutureEvent'),
     payload('delivery').except('Metadata')].each do |record|
      expect { deliver(record) }.not_to change(EmailEvent, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('ignored' => true)
      expect(PendingEmailEvent.count).to eq(0)
    end
  end

  it 'chooses the matching recipient case-insensitively and accepts the underscore metadata alias' do
    other = create(:email_event, account:, emailable: template, event_type: 'send',
                                 message_id: send_event.message_id, email: 'second@example.com')
    record = payload('delivery').merge('Recipient' => 'SECOND@example.com',
                                       'Metadata' => { 'message_uuid' => send_event.message_id })
    deliver(record)

    expect(EmailEvent.order(:id).last).to have_attributes(emailable: template, email: 'SECOND@example.com',
                                                          tag: other.tag)
  end

  it 'falls back to the first send when no recipient matches' do
    deliver(payload('delivery').merge('Recipient' => 'unknown@example.com'))

    expect(EmailEvent.order(:id).last.emailable).to eq(submitter)
  end

  it 'records non-Submitter mail without a signer timeline row' do
    send_event.update!(emailable: template)

    expect { deliver(payload('open')) }.not_to change(SubmissionEvent, :count)
    expect(EmailEvent.order(:id).last.emailable).to eq(template)
  end

  it 'falls back to now for an invalid timestamp and still deduplicates the original bytes' do
    freeze_time do
      record = payload('delivery').merge('DeliveredAt' => 'not-a-time')
      deliver(record)
      expect(EmailEvent.order(:id).last.event_datetime).to eq(Time.current)

      expect { deliver(record) }.not_to change(EmailEvent, :count)
      expect(response.parsed_body).to eq('duplicate' => true)
    end
  end

  it 'treats every permanent type and an inactive soft bounce as permanent' do
    %w[HardBounce BadEmailAddress Blocked DnsError SpamNotification].each do |type|
      record = payload('bounce_soft').merge('Type' => type, 'ID' => type)
      deliver(record)
      expect(EmailEvent.order(:id).last.event_type).to eq('permanent_bounce')
    end

    deliver(payload('bounce_soft').merge('Inactive' => true))
    expect(EmailEvent.order(:id).last.event_type).to eq('permanent_bounce')
  end

  %w[Unsubscribe ManuallyDeactivated].each do |type|
    it "records #{type} as suppression and excludes it from the bounce pause even when inactive" do
      stub_const('Quotas::Limits::BOUNCE_MIN_SENDS', 1)
      stub_const('Quotas::Limits::BOUNCE_PAUSE_RATE', 0.2)
      record = payload('bounce_hard').merge('Type' => type)

      expect { deliver(record) }.not_to change(SubmissionEvent, :count)
      expect(response.parsed_body).to eq('recorded' => true)
      expect(EmailEvent.order(:id).last.event_type).to eq('suppressed')
      expect(SendingPause.bounce_rate(account)).to be_nil
      expect(SendingPause.paused?(account)).to be(false)
    end
  end

  it 'retains a Postmark click without duplicating the app-owned click timeline row' do
    SubmissionEvent.create!(submitter:, event_type: 'click_email')

    expect { deliver(payload('click')) }.not_to change(SubmissionEvent, :count)
    expect(response.parsed_body).to eq('recorded' => true)
    expect(EmailEvent.order(:id).last.event_type).to eq('click')
    expect(submitter.submission.submission_events.sole.event_type).to eq('click_email')
  end

  %w[SoftBounce Transient].each do |type|
    it "records #{type} without presenting a signer failure" do
      expect { deliver(payload('bounce_soft').merge('Type' => type)) }.not_to change(SubmissionEvent, :count)

      expect(response.parsed_body).to eq('recorded' => true)
      expect(EmailEvent.order(:id).last.event_type).to eq('soft_bounce')
    end
  end

  %w[bounce_hard spam_complaint open].each do |fixture|
    it "keeps a CC/BCC #{fixture} off the signer timeline" do
      copy = create(:email_event, account:, emailable: submitter, event_type: 'send',
                                  message_id: send_event.message_id, email: 'copy@example.com', tag: 'copy')
      record = payload(fixture).merge('Recipient' => 'COPY@example.com', 'Email' => 'COPY@example.com')

      expect { deliver(record) }.not_to change(SubmissionEvent, :count)
      expect(response.parsed_body).to eq('recorded' => true)
      event = EmailEvent.order(:id).last
      expect(event).to have_attributes(email: 'COPY@example.com', emailable: submitter, tag: copy.tag)
      expect(event.data).not_to have_key('recipient_mismatch')
    end
  end

  it 'flags fallback attribution and never projects an unmatched address, even if it is the signer' do
    send_event.update!(email: 'copy@example.com')

    expect { deliver(payload('bounce_hard')) }.not_to change(SubmissionEvent, :count)
    event = EmailEvent.order(:id).last
    expect(response.parsed_body).to eq('recorded' => true)
    expect(event).to have_attributes(email: submitter.email, emailable: submitter, message_id: send_event.message_id)
    expect(event.data).to include('recipient_mismatch' => true)
  end

  it 'projects a signer bounce when the address matches case-insensitively' do
    deliver(payload('bounce_hard').merge('Email' => 'SIGNER@example.com'))

    expect(response.parsed_body).to eq('recorded' => true)
    expect(submitter.submission.submission_events.sole.event_type).to eq('bounce_email')
  end

  it 'pauses a customer complaint, opens an abuse flag, and enqueues admin and operator mail' do
    allow(QuotaMailer).to receive(:sending_paused).and_call_original
    allow(OperatorMailer).to receive(:alert).and_call_original

    deliver(payload('spam_complaint'))

    expect(response).to have_http_status(:ok)
    expect(SendingPause.paused?(account)).to be(true)
    expect(account.abuse_flags.open.where(kind: 'complaint').count).to eq(1)
    expect(QuotaMailer).to have_received(:sending_paused).with(account, 'complaint').once
    expect(OperatorMailer).to have_received(:alert).with(/Sending paused/, kind_of(String)).once
    mail_jobs = Sidekiq::Queues.jobs_by_queue.values.flatten.select { |job| job['wrapped'] == 'ActionMailer::MailDeliveryJob' }
    expect(mail_jobs.map { |job| job.dig('args', 0, 'arguments', 0) }).to include('QuotaMailer', 'OperatorMailer')
  end

  it 'pauses for three hard bounces among ten distinct sends' do
    stub_const('Quotas::Limits::BOUNCE_MIN_SENDS', 10)
    stub_const('Quotas::Limits::BOUNCE_PAUSE_RATE', 0.2)
    sends = [send_event] + Array.new(9) do
      create(:email_event, account:, emailable: submitter, event_type: 'send', email: 'signer@example.com')
    end
    sends.first(3).each_with_index do |sent, index|
      record = payload('bounce_hard').merge('ID' => 900 + index,
                                            'Metadata' => { 'message-uuid' => sent.message_id })
      deliver(record)
    end

    expect(SendingPause.paused?(account)).to be(true)
    expect(account.reload.sending_pause_reason).to eq('bounce_rate')
    expect(account.abuse_flags.open.where(kind: 'bounce_rate').count).to eq(1)
  end

  it 'records internal complaints but never pauses internal sending' do
    account.update!(account_kind: Account::INTERNAL_KIND)
    deliver(payload('spam_complaint'))

    expect(response.parsed_body).to eq('recorded' => true)
    expect(SendingPause.paused?(account)).to be(false)
    expect(account.abuse_flags.open).to be_empty
  end

  [RuntimeError, ActiveRecord::RecordNotUnique].each do |failure_class|
    it "rolls back a failed pause write (#{failure_class}) and retries the same complaint" do
      allow(AbuseFlags).to receive(:record!).and_raise(failure_class, 'flag write failed')
      allow(ErrorReport).to receive(:error)
      record = payload('spam_complaint')

      expect { deliver(record) }.not_to change(EmailEvent, :count)
      expect(response).to have_http_status(:internal_server_error)
      expect(SendingPause.paused?(account)).to be(false)
      expect(submitter.submission.submission_events).to be_empty
      expect(account.abuse_flags.open).to be_empty
      expect(ErrorReport).to have_received(:error).with(kind_of(failure_class))

      allow(AbuseFlags).to receive(:record!).and_call_original
      expect { deliver(record) }.to change(EmailEvent, :count).by(1)
      expect(response.parsed_body).to eq('recorded' => true)
      expect(SendingPause.paused?(account)).to be(true)
      expect(account.abuse_flags.open.where(kind: 'complaint').count).to eq(1)
      expect(submitter.submission.submission_events.sole.event_type).to eq('complaint_email')
    end
  end

  it 'keeps the pause and operator alert when customer mail cannot be enqueued' do
    mail = instance_double(ActionMailer::MessageDelivery)
    allow(mail).to receive(:deliver_later!).and_raise(RuntimeError, 'customer queue unavailable')
    allow(QuotaMailer).to receive(:sending_paused).and_return(mail)
    allow(OperatorAlert).to receive(:deliver).and_call_original
    allow(ErrorReport).to receive(:error)

    deliver(payload('spam_complaint'))

    expect(response.parsed_body).to eq('recorded' => true)
    expect(SendingPause.paused?(account)).to be(true)
    expect(account.abuse_flags.open.where(kind: 'complaint').count).to eq(1)
    expect(OperatorAlert).to have_received(:deliver).once
    expect(ErrorReport).to have_received(:error).with(kind_of(RuntimeError), account_id: account.id)
    queued = Sidekiq::Queues.jobs_by_queue.values.flatten.to_json
    expect(queued).to include('OperatorMailer')
  end

  it 'attempts the operator alert before customer mail and still mails the customer if the alert fails' do
    attempts = []
    allow(OperatorAlert).to receive(:deliver) do
      attempts << :operator
      raise 'operator queue unavailable'
    end
    allow(QuotaMailer).to receive(:sending_paused).and_wrap_original do |original, *args|
      attempts << :customer
      original.call(*args)
    end
    allow(ErrorReport).to receive(:error)

    deliver(payload('spam_complaint'))

    expect(response.parsed_body).to eq('recorded' => true)
    expect(attempts).to eq(%i[operator customer])
    expect(SendingPause.paused?(account)).to be(true)
    expect(ErrorReport).to have_received(:error).with(kind_of(RuntimeError), account_id: account.id)
    expect(Sidekiq::Queues.jobs_by_queue.values.flatten.to_json).to include('QuotaMailer')
  end

  it 'rolls back both rows on a projection failure, then records a retry exactly once' do
    allow(SubmissionEvent).to receive(:create!).and_raise(RuntimeError, 'projection failed')
    allow(ErrorReport).to receive(:error)

    expect { deliver(payload('open')) }.not_to change(EmailEvent, :count)
    expect(response).to have_http_status(:internal_server_error)
    expect(ErrorReport).to have_received(:error).with(kind_of(RuntimeError))

    allow(SubmissionEvent).to receive(:create!).and_call_original
    expect { deliver(payload('open')) }.to change(EmailEvent, :count).by(1)
    deliver(payload('open'))
    expect(response.parsed_body).to eq('duplicate' => true)
    expect(submitter.submission.submission_events.count).to eq(1)
  end

  # The two headers are one uuid: ours keys the send rows, Postmark's quotes it
  # back in every callback. The Postmark copy is only stamped on a message that
  # HAS metadata, because that is the only kind a send row is written for
  # (review 2, M4 — the pair of examples further down proves both sides of
  # that with real mailers).
  it 'places the same UUID in the observer and Postmark metadata headers' do
    mailer = ApplicationMailer.new
    mailer.put_metadata('tag' => 'probe', 'record_id' => account.id, 'record_type' => 'Account')
    mailer.set_message_uuid

    expect(mailer.message['X-PM-Metadata-message-uuid'].value).to eq(mailer.message['X-Message-Uuid'].value)
  end

  # ---------------------------------------------------------------------------
  # The SaaS lifecycle mail (Session 10; review 8, C3)
  #
  # "We suspended this account on day 14" is only half a sentence. The other
  # half is "and here is the delivery record of the warning we sent first",
  # and until this session there was none: the dunning letters, the suspension
  # notice, invitations and quota warnings set no message metadata, so no send
  # row was written and every Postmark event about them was dropped.
  # ---------------------------------------------------------------------------
  describe 'the platform’s own letters to a customer' do
    let!(:admin) { create(:user, :admin, account:, email: 'owner@example.com') }

    # Every customer-facing lifecycle mailer, driven the way its callers drive
    # it. A mailer added to this family and NOT tracked fails here.
    def lifecycle_mails
      { 'billing_payment_failed' => -> { BillingMailer.payment_failed(account, day: 0) },
        'billing_suspended' => -> { BillingMailer.suspended(account) },
        'quota_completions_warning' => -> { QuotaMailer.completions_warning(account) },
        'quota_sending_paused' => -> { QuotaMailer.sending_paused(account, 'complaint') },
        'account_deletion_scheduled_to' => -> { AccountMailer.deletion_scheduled(account) },
        'account_invite_invitation' => lambda {
          # `seats_bought` skips the seat check: this example is about the
          # message, not about whether a free account may invite anybody.
          invite = AccountInvites.reserve!(account:, email: 'joiner@example.com', role: 'admin',
                                           invited_by: admin, seats_bought: 1)
          AccountInviteMailer.invitation(invite, invite.raw_token)
        },
        'settings_smtp_successful_setup' => -> { SettingsMailer.smtp_successful_setup(admin.email, account) } }
    end

    it 'writes one send row per letter, attributed to the account itself' do
      lifecycle_mails.each do |tag, build|
        expect { build.call.deliver_now! }.to change(EmailEvent, :count).by(1)

        event = EmailEvent.order(:id).last

        expect(event).to have_attributes(tag:, event_type: 'send', emailable: account, account:)
        expect(event.message_id).to be_present
      end
    end

    # The whole point of the send row: the bounce that follows it is
    # attributable instead of being dropped as `{ ignored: true }`.
    it 'records a bounce of a dunning letter against the account' do
      BillingMailer.payment_failed(account, day: 0).deliver_now!
      sent = EmailEvent.order(:id).last

      record = payload('bounce_hard').merge('Metadata' => { 'message-uuid' => sent.message_id },
                                            'Email' => admin.email, 'Recipient' => admin.email)

      expect { deliver(record) }.to change(EmailEvent, :count).by(1)
      expect(response.parsed_body).to eq('recorded' => true)
      expect(EmailEvent.order(:id).last).to have_attributes(event_type: 'permanent_bounce', emailable: account,
                                                            account:, tag: 'billing_payment_failed')
    end

    # And the line that must NOT be crossed: an account is never stopped from
    # sending because a letter WE sent THEM bounced. The pause is about the
    # mail an account sends its signers.
    it 'never lets a lifecycle bounce or complaint feed the abuse pause' do
      stub_const('Quotas::Limits::BOUNCE_MIN_SENDS', 1)
      stub_const('Quotas::Limits::BOUNCE_PAUSE_RATE', 0.1)

      BillingMailer.payment_failed(account, day: 0).deliver_now!
      sent = EmailEvent.order(:id).last

      %w[bounce_hard spam_complaint].each do |fixture|
        record = payload(fixture).merge('Metadata' => { 'message-uuid' => sent.message_id },
                                        'ID' => "lifecycle-#{fixture}",
                                        'Email' => admin.email, 'Recipient' => admin.email)
        deliver(record)

        expect(response.parsed_body).to eq('recorded' => true)
      end

      expect(SendingPause.paused?(account)).to be(false)
      expect(account.reload.abuse_flags.open).to be_empty
      expect(submitter.submission.submission_events).to be_empty
    end

    # The maths as well as the trigger: lifecycle deliveries must not dilute
    # the signer-mail window either, or a chatty billing month would quietly
    # raise the number of signer bounces an account can have.
    it 'keeps lifecycle deliveries out of the bounce window' do
      stub_const('Quotas::Limits::BOUNCE_MIN_SENDS', 4)
      stub_const('Quotas::Limits::BOUNCE_PAUSE_RATE', 0.5)

      4.times { BillingMailer.payment_failed(account, day: 0).deliver_now! }

      # Four deliveries exist, but only the one signer send counts, so the
      # window is under BOUNCE_MIN_SENDS and no rate can be computed at all.
      expect(EmailEvent.where(account:, event_type: 'send').count).to eq(5)
      expect(SendingPause.send(:recent_deliveries, [account.id]).size).to eq(1)
      expect(SendingPause.bounce_rate(account)).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # A1: the resume watermark
  # ---------------------------------------------------------------------------
  describe 'resuming a paused account' do
    def bounce_three_of_ten!
      sends = [send_event] + Array.new(9) do
        create(:email_event, account:, emailable: submitter, event_type: 'send', email: 'signer@example.com')
      end

      sends.first(3).each_with_index do |sent, index|
        deliver(payload('bounce_hard').merge('ID' => 800 + index,
                                             'Metadata' => { 'message-uuid' => sent.message_id }))
      end
    end

    before do
      stub_const('Quotas::Limits::BOUNCE_MIN_SENDS', 10)
      stub_const('Quotas::Limits::BOUNCE_PAUSE_RATE', 0.2)
    end

    it 'starts the bounce window again, so the same bounces cannot re-pause it' do
      bounce_three_of_ten!

      expect(SendingPause.paused?(account)).to be(true)

      SendingPause.resume!(account)

      expect(account.reload.sending_resumed_at).to be_present
      # The window is empty: every delivery in it happened before the operator
      # looked at the account and decided.
      expect(SendingPause.bounce_rate(account)).to be_nil
      expect(SendingPause.send(:recent_deliveries, [account.id])).to be_empty

      # And one more bounce of the SAME old mail does not put it back.
      deliver(payload('bounce_hard').merge('ID' => 'after-resume',
                                           'Metadata' => { 'message-uuid' => send_event.message_id }))

      expect(response.parsed_body).to eq('recorded' => true)
      expect(SendingPause.paused?(account)).to be(false)
    end

    # M5: the complaint side used to ignore the watermark entirely, so the
    # operator's Resume was undone by the next complaint about the same
    # pre-resume batch — spam complaints reach us hours or days late.
    it 'is not re-paused by a late complaint about a delivery made before the resume' do
      deliver(payload('spam_complaint').merge('ID' => 'first-complaint'))

      expect(SendingPause.paused?(account)).to be(true)

      SendingPause.resume!(account)

      expect(SendingPause.paused?(account)).to be(false)

      deliver(payload('spam_complaint').merge('ID' => 'late-complaint'))

      expect(response.parsed_body).to eq('recorded' => true)
      expect(SendingPause.paused?(account)).to be(false)
    end

    it 'still pauses on a complaint about a delivery made after the resume' do
      SendingPause.resume!(account)

      fresh = create(:email_event, account:, emailable: submitter, event_type: 'send',
                                   email: 'signer@example.com', event_datetime: 1.minute.from_now)

      deliver(payload('spam_complaint').merge('ID' => 'fresh-complaint',
                                              'Metadata' => { 'message-uuid' => fresh.message_id }))

      expect(SendingPause.paused?(account)).to be(true)
      expect(account.reload.sending_pause_reason).to eq('complaint')
    end

    it 'still pauses on bounces earned after the resume' do
      bounce_three_of_ten!
      SendingPause.resume!(account)

      fresh = Array.new(10) do
        create(:email_event, account:, emailable: submitter, event_type: 'send', email: 'signer@example.com',
                             event_datetime: 1.minute.from_now)
      end

      fresh.first(3).each_with_index do |sent, index|
        deliver(payload('bounce_hard').merge('ID' => 700 + index,
                                             'Metadata' => { 'message-uuid' => sent.message_id }))
      end

      expect(SendingPause.paused?(account)).to be(true)
      expect(account.reload.sending_pause_reason).to eq('bounce_rate')
    end
  end

  # ---------------------------------------------------------------------------
  # D8: a callback that arrives before its own send row
  # ---------------------------------------------------------------------------
  describe 'a callback that overtakes its send row' do
    let(:early_uuid) { SecureRandom.uuid }
    let(:early_bounce) { payload('bounce_hard').merge('Metadata' => { 'message-uuid' => early_uuid }) }

    it 'parks it instead of dropping it, and parks a retry only once' do
      expect { deliver(early_bounce) }.to change(PendingEmailEvent, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('parked' => true)
      expect(EmailEvent.where(event_type: 'permanent_bounce').count).to eq(0)

      expect { deliver(early_bounce) }.not_to change(PendingEmailEvent, :count)
      expect(response.parsed_body).to eq('parked' => true)

      parked = PendingEmailEvent.sole

      expect(parked.provider_message_id).to eq(early_uuid)
      expect(parked.record['RecordType']).to eq('Bounce')
    end

    # The send row is written by an observer that runs after the message has
    # been handed over, so THIS is the moment the parked event belongs to.
    it 'attributes it the moment the send row is written' do
      deliver(early_bounce)

      # The mail is built with the uuid the webhook already named — which is
      # exactly the ordering being reproduced: the callback came back before
      # the observer wrote the row for that message.
      allow(SecureRandom).to receive(:uuid).and_return(early_uuid)
      submitter.update!(email: 'signer@example.com')
      SubmitterMailer.invitation_email(submitter).deliver_now!

      expect(PendingEmailEvent.count).to eq(0)

      bounce = EmailEvent.where(event_type: 'permanent_bounce').sole

      expect(bounce).to have_attributes(message_id: early_uuid, emailable: submitter, account:)
      expect(submitter.submission.submission_events.map(&:event_type)).to include('bounce_email')
    end

    it 'is attributed by the hourly sweep when the send row lands another way' do
      deliver(early_bounce)

      create(:email_event, account:, emailable: submitter, event_type: 'send',
                           message_id: early_uuid, email: 'signer@example.com')

      expect { HousekeepingJob.new.perform }.to change(PendingEmailEvent, :count).by(-1)
      expect(EmailEvent.where(event_type: 'permanent_bounce').sole.message_id).to eq(early_uuid)
      expect(SchedulerStamps.all['housekeeping']).to include('outcome' => 'ok', 'error' => nil)
    end

    it 'drops a parked callback whose send row never came, and keeps a fresh one waiting' do
      deliver(early_bounce)
      PendingEmailEvent.sole.update!(created_at: (PendingEmailEvent::MAX_WAIT + 1.day).ago)
      deliver(payload('bounce_hard').merge('ID' => 'second-early',
                                           'Metadata' => { 'message-uuid' => SecureRandom.uuid }))

      expect { HousekeepingJob.new.perform }.to change(PendingEmailEvent, :count).by(-1)
      expect(PendingEmailEvent.sole.provider_message_id).not_to eq(early_uuid)
      expect(EmailEvent.where(event_type: 'permanent_bounce').count).to eq(0)
    end

    # M8. A replay that RAISES is not a callback nobody can claim: its send row
    # is right there and the write broke. Postmark has already been answered
    # 200, so dropping it at three days with the never-matched ones loses a
    # real bounce for good.
    it 'keeps a callback whose replay failed, counts the attempts and never expires it' do
      deliver(early_bounce)

      create(:email_event, account:, emailable: submitter, event_type: 'send',
                           message_id: early_uuid, email: 'signer@example.com')

      allow(PostmarkWebhooks).to receive(:persist!).and_raise(ActiveRecord::StatementInvalid, 'timeline write failed')

      expect { HousekeepingJob.new.perform }.not_to change(PendingEmailEvent, :count)

      parked = PendingEmailEvent.sole

      expect(parked.attempts).to eq(1)
      expect(parked.attribution_error).to include('timeline write failed')
      expect(parked.last_attempted_at).to be_present

      # Three days old and still kept, because this one CAN be attributed. The
      # next try is the next hourly tick: a row that has just failed is left
      # alone until then (PostmarkWebhooks::RETRY_INTERVAL), so that the small
      # share of the sweep the failures get is spread over all of them.
      parked.update!(created_at: (PendingEmailEvent::MAX_WAIT + 1.day).ago)

      travel(PostmarkWebhooks::RETRY_INTERVAL + 1.minute) do
        expect { HousekeepingJob.new.perform }.not_to change(PendingEmailEvent, :count)
        expect(PendingEmailEvent.sole.attempts).to eq(2)
      end

      # And once the write works again, the sweep lands it.
      allow(PostmarkWebhooks).to receive(:persist!).and_call_original

      travel(3 * PostmarkWebhooks::RETRY_INTERVAL) do
        expect { HousekeepingJob.new.perform }.to change(PendingEmailEvent, :count).by(-1)
      end

      expect(EmailEvent.where(event_type: 'permanent_bounce').sole.message_id).to eq(early_uuid)
    end

    # N3. One alert per row, sent by the sweep that takes it OVER the
    # threshold. Alerting on the STATE instead mailed the operator the same
    # alert every hour for ever — these rows are retried by every tick and
    # never expire — and alert fatigue is how the next real alert is ignored.
    it 'tells the operator when a failed replay crosses the threshold, and not again every hour after' do
      deliver(early_bounce)

      create(:email_event, account:, emailable: submitter, event_type: 'send',
                           message_id: early_uuid, email: 'signer@example.com')

      PendingEmailEvent.sole.update!(attempts: PostmarkWebhooks::MAX_REPLAY_ATTEMPTS - 1,
                                     attribution_error: 'ActiveRecord::StatementInvalid: timeline write failed',
                                     last_attempted_at: 2.hours.ago)

      allow(PostmarkWebhooks).to receive(:persist!).and_raise(ActiveRecord::StatementInvalid, 'timeline write failed')
      allow(OperatorAlert).to receive(:deliver)

      PostmarkWebhooks.sweep_pending!

      expect(PendingEmailEvent.sole.attempts).to eq(PostmarkWebhooks::MAX_REPLAY_ATTEMPTS)
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(subject: a_string_including('cannot be replayed'))).once

      # An hour later it is the same row failing the same way, which is not
      # news; the operator is told again only when it is finally dropped.
      PendingEmailEvent.sole.update!(last_attempted_at: 2.hours.ago)

      PostmarkWebhooks.sweep_pending!

      expect(PendingEmailEvent.sole.attempts).to eq(PostmarkWebhooks::MAX_REPLAY_ATTEMPTS + 1)
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(subject: a_string_including('cannot be replayed'))).once
    end

    # The other end of N3/N4: kept is not kept for ever. A replay that has
    # failed a full day of hourly retries is a bug to fix from the alert, and
    # leaving it in the table costs every later row its place in the batch.
    it 'drops a replay that has failed all day and says out loud what was lost' do
      deliver(early_bounce)

      PendingEmailEvent.sole.update!(attempts: PostmarkWebhooks::MAX_ATTEMPTS,
                                     attribution_error: 'ActiveRecord::StatementInvalid: timeline write failed',
                                     last_attempted_at: 2.hours.ago)

      allow(OperatorAlert).to receive(:deliver)

      expect(PostmarkWebhooks.sweep_pending!).to eq(pending: 0, dropped: 1, errored: 0)
      expect(OperatorAlert).to have_received(:deliver)
        .with(hash_including(subject: a_string_including('dropped after failing to replay')))
    end

    # N4. Failed rows are deliberately never dropped by the three-day clock, so
    # a batch's worth of them sitting at the head of the table meant the plain
    # `order(:id).limit` walk retried only those, every hour, for ever: a newer
    # callback whose send row had since landed was never reached at all and
    # aged out at three days, losing a real bounce.
    it 'reaches a newer callback parked behind a full batch of failures' do
      stub_const('PostmarkWebhooks::SWEEP_BATCH', 1)
      stub_const('PostmarkWebhooks::FAILED_BATCH', 1)

      deliver(early_bounce)
      PendingEmailEvent.sole.update!(attempts: 3, last_attempted_at: 2.hours.ago,
                                     attribution_error: 'ActiveRecord::StatementInvalid: timeline write failed')

      later_uuid = SecureRandom.uuid

      deliver(payload('bounce_hard').merge('ID' => 'later-bounce', 'Metadata' => { 'message-uuid' => later_uuid }))

      create(:email_event, account:, emailable: submitter, event_type: 'send',
                           message_id: later_uuid, email: 'signer@example.com')

      expect { PostmarkWebhooks.sweep_pending! }.to change(PendingEmailEvent, :count).by(-1)
      expect(EmailEvent.where(event_type: 'permanent_bounce').sole.message_id).to eq(later_uuid)
      # The stuck one is still parked, still failed, still being retried.
      expect(PendingEmailEvent.sole.provider_message_id).to eq(early_uuid)
    end

    it 'counts what it dropped without counting it as still waiting' do
      deliver(early_bounce)
      PendingEmailEvent.sole.update!(created_at: (PendingEmailEvent::MAX_WAIT + 1.day).ago)

      expect(PostmarkWebhooks.sweep_pending!).to eq(pending: 0, dropped: 1, errored: 0)
    end
  end

  # ---------------------------------------------------------------------------
  # M4: mail nobody is tracking is not stamped, so its callbacks are not parked
  # ---------------------------------------------------------------------------
  describe 'a message with no account behind it' do
    # OperatorMailer and SupportMailer write to US. They name no account, so no
    # send row is ever written for them — and while they still stamped the
    # Postmark metadata uuid, every Postmark event about them (delivery and
    # open included) was PARKED for three days and then dropped, which made the
    # sweep's `dropped` alarm permanently non-zero and therefore useless.
    it 'carries no Postmark metadata uuid, so its callbacks are ignored rather than parked' do
      mail = OperatorMailer.alert('Something happened', 'body')
      mail.deliver_now!

      expect(mail['X-Message-Uuid']).to be_present
      expect(mail['X-PM-Metadata-message-uuid']).to be_nil
      expect(EmailEvent.where(tag: 'operator_alert')).not_to exist

      expect do
        deliver(payload('bounce_hard').merge('ID' => 'operator-mail', 'Metadata' => {}))
      end.not_to change(PendingEmailEvent, :count)

      expect(response.parsed_body).to eq('ignored' => true)
    end

    # N2. SupportMailer names a tag and a topic and no record, so metadata was
    # PRESENT and the message was stamped — while the observer, which needs the
    # record the message is ABOUT, still wrote no send row. Every Postmark
    # callback for a support-form email was parked for three days and then
    # dropped: exactly the noise M4 was raised to remove.
    it 'does not stamp mail that names a tag but still no record' do
      mail = SupportMailer.request_received(name: 'Grace Hopper', email: 'grace@example.com', topic: 'billing',
                                            topic_label: 'Billing and plans', message: 'A question', ip: '203.0.113.9')
      mail.deliver_now!

      expect(mail['X-Message-Uuid']).to be_present
      expect(mail['X-PM-Metadata-message-uuid']).to be_nil
      expect(EmailEvent.where(tag: 'support_request')).not_to exist

      expect do
        deliver(payload('bounce_hard').merge('ID' => 'support-mail', 'Metadata' => {}))
      end.not_to change(PendingEmailEvent, :count)
    end

    # Customer mail still is: naming the account is what makes it trackable.
    it 'still stamps a message that names an account' do
      submitter.update!(email: 'signer@example.com')

      mail = SubmitterMailer.invitation_email(submitter)
      mail.deliver_now!

      expect(mail['X-PM-Metadata-message-uuid']).to be_present
      expect(mail['X-PM-Metadata-message-uuid'].value).to eq(mail['X-Message-Uuid'].value)
    end
  end
end
