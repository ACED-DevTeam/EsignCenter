# frozen_string_literal: true

# Free accounts are hard-capped at 5 first-signer completions, 15 sends and 10
# open documents per UTC month on every creation path; share links pause and
# resume by computation; paid accounts are never blocked; internal accounts
# are exempt.
#
# Every completion here is a REAL one: a signer's PUT /s/:slug with consent
# (SigningHelpers#complete!) under `sidekiq: :inline`, so the completion job
# writes the completed_submitters row the way production does. No example
# inserts a completed_submitters row directly. Every refusal asserts that
# nothing was persisted and no job was enqueued (the refusal itself runs with
# Sidekiq in fake mode so an enqueued job would be visible).
#
# The creation-lock group at the bottom is a second top-level group on
# purpose (see its comment): it runs without the wrapping test transaction.
RSpec.describe 'Quotas', type: :request do # rubocop:disable RSpec/MultipleDescribes
  let!(:free_account) { create(:account) }
  let!(:paid_account) { create(:account, :paid) }
  let!(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }
  let(:json_headers) { { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' } }
  let(:reset_date) { Quotas.resets_at.strftime('%Y-%m-%d') }
  let(:completions_alert) { I18n.t('quota_reached_completions', limit: 5, date: reset_date) }
  let(:sends_alert) { I18n.t('quota_reached_sends', limit: 15, date: reset_date) }
  let(:in_flight_alert) { I18n.t('quota_reached_in_flight', limit: 10, date: reset_date) }
  let(:paused_alert) { I18n.t('sending_paused_alert') }
  let(:signer_page) { I18n.t('form_not_accepting_responses') }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before do
    platform_certificate!
    deliveries.clear
  end

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

  def anonymous!
    sign_out(:user)
    reset!
  end

  def text_template_for(account, **attrs)
    create(:template, account:, author: admin_for(account), only_field_types: %w[text], **attrs)
  end

  def unique_email
    "signer-#{SecureRandom.hex(4)}@example.com"
  end

  # One real send through the service every creation path shares.
  def send_one(account, template: text_template_for(account), email: unique_email)
    Submissions.create_from_emails(template:, user: admin_for(account), emails: email, source: :invite,
                                   mark_as_sent: true).sole
  end

  # One real completion: send, then the signer's PUT /s/:slug.
  def complete_one!(account, template: text_template_for(account), email: unique_email)
    complete!(send_one(account, template:, email:).submitters.first)
  end

  def cap_completions!(account, template: text_template_for(account))
    Array.new(Quotas::Limits::FREE_COMPLETIONS_PER_MONTH) { complete_one!(account, template:) }
  end

  # A free account can never hold more than 10 open documents, so reaching
  # the send cap means resolving some on the way: `resolve` of them are
  # deleted from the dashboard (archived) — which, as the sends examples
  # prove, never gives the send back.
  def send_many(account, template:, count:, resolve:)
    sent = Array.new([count, Quotas::Limits::FREE_IN_FLIGHT].min) { send_one(account, template:) }
    sent.first(resolve).each { |submission| submission.update!(archived_at: Time.current) }
    sent + Array.new(count - sent.size) { send_one(account, template:) }
  end

  # The refusal under test runs with Sidekiq in fake mode so a job enqueued
  # by mistake shows up in Sidekiq::Worker.jobs instead of running silently.
  def with_fake_sidekiq
    previous = if Sidekiq::Testing.inline?
                 :inline
               elsif Sidekiq::Testing.disabled?
                 :disable
               else
                 :fake
               end

    Sidekiq.testing!(:fake)
    Sidekiq::Worker.clear_all

    yield
  ensure
    # Put back the mode this example was actually running in. Restoring a
    # hard-coded :inline would leak inline jobs into every later example.
    Sidekiq.testing!(previous)
  end

  # Templates are part of the state: a refused send must leave the template
  # (its "save message" preferences included) exactly as it was.
  def persisted_state
    [Submission.count, Submitter.count, AccountCounter.sum(:value), AbuseFlag.count, deliveries.size,
     Template.order(:id).pluck(:updated_at, :preferences)]
  end

  def refusing
    with_fake_sidekiq do
      state_before = persisted_state

      yield

      expect(persisted_state).to eq(state_before)
      expect(Sidekiq::Worker.jobs).to be_empty
    end
  end

  def post_recipients(template, params)
    post "/templates/#{template.id}/submissions", params:
  end

  def html_submission_params(template)
    { submission: { '1' => { submitters: [{ uuid: template.submitters.first['uuid'], email: unique_email }] } },
      send_email: '1' }
  end

  def api_submission_params(template)
    { template_id: template.id, submitters: [{ role: template.submitters.first['name'], email: unique_email }] }
  end

  def mcp_send(account, template)
    token = admin_for(account).mcp_tokens.create!(name: 'Golden')
    create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)
    call = { name: 'send_documents', arguments: { template_id: template.id, submitters: [{ email: unique_email }] } }

    post '/mcp', headers: { 'Authorization' => "Bearer #{token.token}", **json_headers },
                 params: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: call }.to_json
  end

  def invite(email)
    post '/users', params: { user: { email:, first_name: 'New', last_name: 'Person', role: 'admin' } }
  end

  describe 'D41 metering' do
    it 'counts a two-signer document once: 1 after the first signer completes, still 1 after the second',
       sidekiq: :inline do
      template = text_template_for(free_account, submitter_count: 2)
      submitters = template.submitters.map { |s| { uuid: s['uuid'], email: unique_email } }
      submission = Submissions.create_from_submitters(
        template:, user: admin_for(free_account), source: :invite, submitters_order: 'random',
        submissions_attrs: [{ submitters: }.with_indifferent_access]
      ).sole
      first, second = submission.submitters.order(:id).to_a

      expect(Quotas.completions_this_month(free_account)).to eq(0)

      complete!(first)

      expect(Quotas.completions_this_month(free_account)).to eq(1)
      expect(CompletedSubmitter.find_by!(submitter: first).is_first).to be(true)

      complete!(second)

      expect(Quotas.completions_this_month(free_account)).to eq(1)
      expect(CompletedSubmitter.find_by!(submitter: second).is_first).to be(false)
    end

    it 'never adds for a re-completion of the same submitter, a declined document or an expired one',
       sidekiq: :inline do
      submitter = complete_one!(free_account)

      expect(Quotas.completions_this_month(free_account)).to eq(1)

      # A second completion request for the same signer is refused by the
      # form; the completion job re-run (a resend, a webhook retry) finds
      # the existing row and adds nothing.
      put "/s/#{submitter.slug}", params: { completed: 'true', esign_consent: 'true',
                                            esign_consent_version: EsignConsent::VERSION,
                                            values: { text_field(submitter)['uuid'] => 'Again' } }

      expect(response).to have_http_status(:unprocessable_content)

      ProcessSubmitterCompletionJob.new.perform('submitter_id' => submitter.id)

      expect(Quotas.completions_this_month(free_account)).to eq(1)
      expect(CompletedSubmitter.where(submitter:).count).to eq(1)

      declined = send_one(free_account).submitters.first
      post "/s/#{declined.slug}/decline", params: { reason: 'No thanks' }

      expect(declined.reload.declined_at).to be_present

      expired = send_one(free_account)
      expired.update!(expire_at: 1.minute.ago)
      ProcessSubmissionExpiredJob.new.perform('submission_id' => expired.id)

      expect(expired.reload).to be_expired
      expect(Quotas.completions_this_month(free_account)).to eq(1)
      expect(Quotas.in_flight(free_account)).to eq(0)
    end

    it 'emails the free warning once at the fourth completion and not again at the fifth', sidekiq: :inline do
      template = text_template_for(free_account)
      warning = ->(mail) { mail.subject.to_s.include?('free document completions this month') }

      3.times { complete_one!(free_account, template:) }

      expect(deliveries.count(&warning)).to eq(0)

      complete_one!(free_account, template:)

      warning_mail = deliveries.select(&warning)

      expect(warning_mail.size).to eq(1)
      expect(warning_mail.sole.subject).to eq('You have used 4 of 5 free document completions this month')
      expect(warning_mail.sole.to).to eq([admin_for(free_account).email])

      complete_one!(free_account, template:)

      expect(Quotas.completions_this_month(free_account)).to eq(5)
      expect(deliveries.count(&warning)).to eq(1)
    end

    it 'still delivers the signed document when the metering hook itself blows up', sidekiq: :inline do
      template = text_template_for(free_account)

      3.times { complete_one!(free_account, template:) }

      allow(ErrorReport).to receive(:error)
      allow(QuotaMailer).to receive(:completions_warning).and_raise(StandardError, 'boom')

      # The fourth completion is the one that mails the free warning, so this
      # is the completion the broken hook runs on. Metering is bookkeeping:
      # it must never cost the signer the document they just signed.
      submitter = send_one(free_account, template:).submitters.first

      complete!(submitter)

      expect(submitter.reload.completed_at).to be_present
      expect(submitter.documents).to be_present
      expect(ErrorReport).to have_received(:error)
        .with(an_instance_of(StandardError), account_id: free_account.id)
    end
  end

  describe 'the seven creation paths on a free account at 5 completions' do
    let(:template) { text_template_for(free_account) }
    let(:capped) { cap_completions!(free_account, template:) }

    before do
      capped
    end

    it 'path 1: the recipients form (emails) redirects with the completions alert and creates nothing',
       sidekiq: :inline do
      act_as(free_account)

      refusing { post_recipients(template, emails: unique_email, send_email: '1') }

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(completions_alert)
    end

    it 'path 2: the recipients form (submitter attributes) redirects with the alert and creates nothing',
       sidekiq: :inline do
      act_as(free_account)

      refusing { post_recipients(template, html_submission_params(template)) }

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(completions_alert)
    end

    it 'path 3: the share link GET shows the paused page and emails the owner once; PUT is 422 and creates nothing',
       sidekiq: :inline do
      template.update!(shared_link: true)
      anonymous!

      get "/d/#{template.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(signer_page)
      expect(response.body).to include(I18n.t('form_not_accepting_responses_hint'))
      expect(response.body).not_to include(completions_alert)

      owner_mail = deliveries.select { |m| m.subject == 'A signer could not open your form' }

      expect(owner_mail.size).to eq(1)
      expect(owner_mail.sole.to).to eq([admin_for(free_account).email])
      expect(owner_mail.sole.body.encoded).to include('all 5 document completions')

      get "/d/#{template.slug}"

      expect(deliveries.count { |m| m.subject == 'A signer could not open your form' }).to eq(1)

      refusing { put "/d/#{template.slug}", params: { submitter: { email: unique_email } } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(signer_page)
    end

    it 'path 3b: the share link PUT on an email-2FA link is refused before any code is emailed',
       sidekiq: :inline do
      template.update!(shared_link: true, preferences: template.preferences.merge('shared_link_2fa' => true))
      anonymous!

      refusing { put "/d/#{template.slug}", params: { submitter: { email: unique_email } } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(signer_page)
      expect(deliveries.count { |m| m.subject.to_s.include?('verification') }).to eq(0)

      refusing do
        put "/d/#{template.slug}", headers: json_headers, params: { submitter: { email: unique_email } }.to_json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => completions_alert)
    end

    it 'path 4: the email-verification code send is 422, sends no code, and names no limit to the signer',
       sidekiq: :inline do
      template.update!(shared_link: true, preferences: template.preferences.merge('shared_link_2fa' => true))
      anonymous!

      refusing do
        post '/start_form_email_2fa_send', params: { slug: template.slug, submitter: { email: unique_email } }
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(deliveries.count { |m| m.subject.to_s.include?('verification') }).to eq(0)

      # The refusal an anonymous holder of the slug gets is the same generic
      # line the paused page shows them: which limit closed this link, the
      # number it is and the date it resets are the account's own business.
      expect(response.parsed_body).to eq('error' => signer_page)
      expect(response.body).not_to include(completions_alert)
      expect(response.body).not_to include(reset_date)
      expect(response.body).not_to include('completion')

      # The other half of the same rule: the account's own signed-in user is
      # told exactly what happened, because only they can act on it.
      act_as(free_account)

      refusing do
        post '/start_form_email_2fa_send', params: { slug: template.slug, submitter: { email: unique_email } }
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => completions_alert)
    end

    it 'path 5: the dashboard resubmit redirects with the alert and creates nothing', sidekiq: :inline do
      # The dashboard offers "resubmit" only for the signed-in user's own row.
      original = capped.last.tap { |s| s.update!(email: admin_for(free_account).email) }
      act_as(free_account)

      refusing { put "/submitters_resubmit/#{original.id}" }

      expect(response).to redirect_to("/s/#{original.slug}")
      expect(flash[:alert]).to eq(completions_alert)
    end

    it 'path 6: API, MCP and signing-session doors share the guard — a paused paid account gets 422, nothing created',
       sidekiq: :inline do
      paid_template = text_template_for(paid_account)
      SendingPause.pause!(paid_account, reason: 'complaint')

      refusing do
        post '/api/submissions', headers: token_headers(paid_account).merge(json_headers),
                                 params: api_submission_params(paid_template).to_json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq('error' => paused_alert)

        post '/api/signing_sessions', headers: token_headers(paid_account).merge(json_headers),
                                      params: api_submission_params(paid_template)
                                        .merge(embed_origin: 'https://app.example.com').to_json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq('error' => paused_alert)

        mcp_send(paid_account, paid_template)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig('result', 'isError')).to be(true)
        expect(response.parsed_body.dig('result', 'content').sole['text']).to eq(paused_alert)
      end
    end

    it 'path 6b: a paused paid account posting a signing session WITH inline documents is refused ' \
       'before a document is stored', sidekiq: :inline do
      SendingPause.pause!(paid_account, reason: 'complaint')
      pdf = Base64.encode64(Rails.root.join('spec/fixtures/sample-document.pdf').read)
      params = { name: 'Inline', embed_origin: 'https://app.example.com',
                 documents: [{ name: 'disclosure.pdf', file: pdf }],
                 submitters: [{ name: 'Borrower', email: unique_email }],
                 fields: [{ name: 'Signature', type: 'signature', role: 'Borrower',
                            areas: [{ x: 0.1, y: 0.8, w: 0.3, h: 0.06, page: 0, document: 0 }] }] }

      stored_before = [Template.count, ActiveStorage::Blob.count]

      # Row counts alone cannot prove this: they roll back with the request's
      # transaction even when the bytes have already been handed to the
      # storage service, which does not roll back. Drop the preflight in
      # SigningSessions::Create and the refusal still happens (the locked
      # re-check) — but the PDF is written first, and this spy is the only
      # thing that sees it.
      allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

      refusing do
        post '/api/signing_sessions', headers: token_headers(paid_account).merge(json_headers),
                                      params: params.to_json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => paused_alert)
      expect([Template.count, ActiveStorage::Blob.count]).to eq(stored_before)
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'path 7: selfsign via the start form is refused with the sender alert and the usage link',
       sidekiq: :inline do
      act_as(free_account)

      refusing { put "/d/#{template.slug}", params: { selfsign: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(completions_alert)
      expect(response.body).to include(I18n.t('upgrade_to_send_more'))
      expect(response.body).to include(%(href="#{Quotas::USAGE_PATH}"))
    end
  end

  describe 'sends' do
    it 'allows the 15th send, refuses the 16th, still completes a sent document, and never resets on delete',
       sidekiq: :inline do
      template = text_template_for(free_account)
      sent = send_many(free_account, template:, count: 15, resolve: 5)

      expect(Quotas.sends_this_month(free_account)).to eq(15)
      expect(Quotas.in_flight(free_account)).to eq(10)

      act_as(free_account)

      refusing { post_recipients(template, emails: unique_email, send_email: '1') }

      expect(flash[:alert]).to eq(sends_alert)

      complete!(sent.last.submitters.first)

      expect(Quotas.completions_this_month(free_account)).to eq(1)

      sent[6].update!(archived_at: Time.current)
      sent[7].destroy!

      expect(Quotas.sends_this_month(free_account)).to eq(15)

      refusing { post_recipients(template, emails: unique_email, send_email: '1') }

      expect(flash[:alert]).to eq(sends_alert)
    end

    it 'refuses a batch of 3 at 13 sends as a whole, then accepts a batch of 2', sidekiq: :inline do
      template = text_template_for(free_account)
      send_many(free_account, template:, count: 13, resolve: 5)
      act_as(free_account)

      refusing { post_recipients(template, emails: Array.new(3) { unique_email }.join(', '), send_email: '1') }

      expect(flash[:alert]).to eq(sends_alert)
      expect(Quotas.sends_this_month(free_account)).to eq(13)

      expect do
        post_recipients(template, emails: Array.new(2) { unique_email }.join(', '), send_email: '1')
      end.to change(Submission, :count).by(2)

      expect(response).to redirect_to("/templates/#{template.id}")
      expect(flash[:notice]).to eq(I18n.t('new_recipients_have_been_added'))
      expect(Quotas.sends_this_month(free_account)).to eq(15)
    end

    it 'counts only the entries that create a document: a batch of 2 with one empty entry passes at 14 sends',
       sidekiq: :inline do
      template = text_template_for(free_account)
      send_many(free_account, template:, count: 14, resolve: 5)
      uuid = template.submitters.first['uuid']
      attrs = [{ submitters: [{ uuid:, email: unique_email }] },
               { submitters: [{ uuid:, email: '' }] }].map(&:with_indifferent_access)

      expect do
        Submissions.create_from_submitters(template:, user: admin_for(free_account), source: :invite,
                                           submitters_order: 'random', submissions_attrs: attrs)
      end.to change(Submission, :count).by(1)

      expect(Quotas.sends_this_month(free_account)).to eq(15)
    end

    it 'lets an operator override win on a free account and ignores one on an internal account',
       sidekiq: :inline do
      template = text_template_for(free_account)
      AccountLimitOverride.create!(account: free_account, sends_per_month: 2)
      2.times { send_one(free_account, template:) }
      act_as(free_account)

      refusing { post_recipients(template, emails: unique_email, send_email: '1') }

      expect(flash[:alert]).to eq(I18n.t('quota_reached_sends', limit: 2, date: reset_date))

      AccountLimitOverride.create!(account: internal_account, sends_per_month: 1, seats: 1)

      expect(Quotas.limits_for(internal_account).to_h.values).to all(be_nil)
      expect(Quotas.assert_seat_available!(internal_account)).to be(true)
      expect(Plans.seats_for(internal_account)).to be_nil
    end
  end

  describe 'documents waiting for signatures' do
    it 'refuses the 11th open document, frees a slot on completion, and does not count a declined one',
       sidekiq: :inline do
      template = text_template_for(free_account)
      open = Array.new(10) { send_one(free_account, template:) }

      expect(Quotas.in_flight(free_account)).to eq(10)

      act_as(free_account)

      refusing { post_recipients(template, emails: unique_email, send_email: '1') }

      expect(flash[:alert]).to eq(in_flight_alert)

      complete!(open[0].submitters.first)

      expect(Quotas.in_flight(free_account)).to eq(9)
      expect { post_recipients(template, emails: unique_email, send_email: '1') }.to change(Submission, :count).by(1)

      post "/s/#{open[1].submitters.first.slug}/decline", params: { reason: 'No' }

      expect(Quotas.in_flight(free_account)).to eq(9)
      expect { post_recipients(template, emails: unique_email, send_email: '1') }.to change(Submission, :count).by(1)

      refusing { post_recipients(template, emails: unique_email, send_email: '1') }

      expect(flash[:alert]).to eq(in_flight_alert)
    end
  end

  describe 'share link pause and resume by time' do
    it 'pauses a capped link and serves it again the next UTC month with nothing persisted or run',
       sidekiq: :inline do
      template = text_template_for(free_account, shared_link: true)
      cap_completions!(free_account, template:)
      anonymous!

      get "/d/#{template.slug}"

      expect(response.body).to include(signer_page)

      account_before = free_account.reload.attributes

      travel_to(Quotas.resets_at + 1.hour) do
        with_fake_sidekiq do
          get "/d/#{template.slug}"

          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include(signer_page)
          expect(response.body).to include(I18n.t('you_have_been_invited_to_submit_a_form'))
          expect(Sidekiq::Worker.jobs).to be_empty
        end

        expect { put "/d/#{template.slug}", params: { submitter: { email: unique_email } } }
          .to change(Submission, :count).by(1)

        expect(response).to redirect_to("/s/#{Submitter.last.slug}")
      end

      expect(free_account.reload.attributes).to eq(account_before)
      expect(AbuseFlag.count).to eq(0)
      expect(AccountLimitOverride.count).to eq(0)
    end
  end

  describe 'paid accounts are never blocked' do
    it 'creates the 501st document on a 1-seat paid account, warns once at 400 and flags fair-use review once',
       sidekiq: :inline do
      # 501 real completions through the real controller and job. The
      # template carries no PDF and no completion emails so each round is
      # the metering path alone, not four minutes of PDF rendering.
      template = text_template_for(paid_account, attachment_count: 0,
                                                 preferences: { 'completed_notification_email_enabled' => false,
                                                                'documents_copy_email_enabled' => false })
      template.update!(fields: [{ 'uuid' => SecureRandom.uuid, 'submitter_uuid' => template.submitters.first['uuid'],
                                  'name' => 'Name', 'type' => 'text', 'required' => true, 'areas' => [] }])
      warning_subject = 'Your EsignCenter account is close to its fair-use level'

      500.times do |i|
        complete_one!(paid_account, template:)

        expect(deliveries.count { |m| m.subject == warning_subject }).to eq(0) if i == 398
        expect(deliveries.count { |m| m.subject == warning_subject }).to eq(1) if i == 399
      end

      expect(Quotas.completions_this_month(paid_account)).to eq(500)
      expect(AbuseFlag.where(account: paid_account, kind: 'fair_use_review').count).to eq(1)
      expect(deliveries.count { |m| m.subject == warning_subject }).to eq(1)

      submission = send_one(paid_account, template:)

      expect(submission).to be_persisted
      expect(Quotas.share_link_paused?(paid_account)).to be_nil

      complete!(submission.submitters.first)

      expect(Quotas.completions_this_month(paid_account)).to eq(501)
      expect(AbuseFlag.where(account: paid_account, kind: 'fair_use_review').count).to eq(1)
    end

    it 'flags a 1-seat paid account once a day past 50 open documents and 200 sends, on the link and resubmit paths',
       sidekiq: :inline do
      template = text_template_for(paid_account, shared_link: true, attachment_count: 0,
                                                 preferences: { 'completed_notification_email_enabled' => false,
                                                                'documents_copy_email_enabled' => false })
      template.update!(fields: [{ 'uuid' => SecureRandom.uuid, 'submitter_uuid' => template.submitters.first['uuid'],
                                  'name' => 'Name', 'type' => 'text', 'required' => true, 'areas' => [] }])
      flags = ->(kind) { AbuseFlag.where(account: paid_account, kind:) }
      anonymous!

      # 200 share-link starts: the open-documents flag appears at the 51st,
      # the velocity flag needs more than 200 sends today.
      200.times do
        put "/d/#{template.slug}", params: { submitter: { email: unique_email } }

        expect(response).to have_http_status(:redirect)
      end

      expect(Quotas.sends_today(paid_account)).to eq(200)
      expect(Quotas.in_flight(paid_account)).to eq(200)
      expect(flags.call('in_flight').count).to eq(1)
      expect(flags.call('send_velocity')).not_to exist

      # The 201st send goes through the dashboard resubmit path.
      own = Submitter.where(account: paid_account).order(:id).last
      own.update!(email: admin_for(paid_account).email)
      complete!(own)
      act_as(paid_account)

      put "/submitters_resubmit/#{own.id}"

      expect(response).to redirect_to("/s/#{Submitter.order(:id).last.slug}")
      expect(Quotas.sends_today(paid_account)).to eq(201)
      expect(flags.call('send_velocity').count).to eq(1)
      expect(flags.call('send_velocity').sole.period).to eq(AccountCounters.day_period)
      expect(flags.call('in_flight').count).to eq(1)
      expect(Quotas.share_link_paused?(paid_account)).to be_nil
    end

    it 'saves the dialog message only once the send went through: a refused paid send leaves the template untouched' do
      template = text_template_for(paid_account)
      SendingPause.pause!(paid_account, reason: 'complaint')
      act_as(paid_account)
      message = { save_message: '1', is_custom_message: '1', subject: 'Please sign', body: 'Custom body' }

      refusing { post_recipients(template, emails: unique_email, send_email: '1', **message) }

      expect(flash[:alert]).to eq(paused_alert)
      expect(template.reload.preferences.keys).not_to include('request_email_subject', 'request_email_body')

      SendingPause.resume!(paid_account)

      expect { post_recipients(template, emails: unique_email, send_email: '1', **message) }
        .to change(Submission, :count).by(1)

      expect(template.reload.preferences).to include('request_email_subject' => 'Please sign',
                                                     'request_email_body' => 'Custom body')
    end
  end

  describe 'internal bypass' do
    it 'lets an internal account past 6 completions and 20 sends, and an operator account past 20 sends',
       sidekiq: :inline do
      create(:encrypted_config, account: internal_account, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: platform_certificate_pems)
      template = text_template_for(internal_account)
      submissions = Submissions.create_from_emails(template:, user: admin_for(internal_account),
                                                   emails: Array.new(20) { unique_email }.join(','),
                                                   source: :invite, mark_as_sent: true)

      expect(submissions.size).to eq(20)

      submissions.first(6).each { |submission| complete!(submission.submitters.first) }

      expect(Quotas.completions_this_month(internal_account)).to eq(6)
      expect(Quotas.sends_this_month(internal_account)).to eq(20)
      expect(Quotas.share_link_paused?(internal_account)).to be_nil
      expect(send_one(internal_account, template:)).to be_persisted

      operator_account = OperatorConfigs.account
      operator_template = text_template_for(operator_account)
      20.times { send_one(operator_account, template: operator_template) }

      expect(send_one(operator_account, template: operator_template)).to be_persisted
      expect(AbuseFlag.count).to eq(0)
      expect(deliveries.count { |m| m.subject.include?('free document completions') }).to eq(0)
    end
  end

  describe 'seats' do
    it 'refuses a free invite, fills a 2-seat paid account, counts a reactivation, and never limits internal' do
      act_as(free_account)

      expect { invite(unique_email) }.not_to change(User, :count)

      expect(response).to redirect_to('/settings/users')
      expect(flash[:alert]).to eq(I18n.t('seat_limit_free'))

      two_seats = create(:account, :paid, seats: 2)
      act_as(two_seats)
      second_email = unique_email

      expect { invite(second_email) }.to change(User, :count).by(1)
      expect { invite(unique_email) }.not_to change(User, :count)

      expect(flash[:alert]).to eq(I18n.t('seat_limit_paid', count: 2))

      User.find_by!(email: second_email).update!(archived_at: Time.current)

      expect { invite(unique_email) }.to change(User, :count).by(1)
      expect { invite(second_email) }.not_to(change { User.find_by!(email: second_email).archived_at })

      expect(flash[:alert]).to eq(I18n.t('seat_limit_paid', count: 2))

      act_as(internal_account)

      expect { 3.times { invite(unique_email) } }.to change(User, :count).by(3)
    end

    it 'refuses the Unarchive button on a full account, allows it with a seat free, and leaves other edits alone' do
      archived = create(:user, account: free_account, archived_at: 1.day.ago)
      act_as(free_account)

      unarchive = -> { put "/users/#{archived.id}", params: { user: { archived_at: '' } } }

      expect { unarchive.call }.not_to(change { archived.reload.archived_at })

      expect(response).to redirect_to('/settings/users')
      expect(flash[:alert]).to eq(I18n.t('seat_limit_free'))

      # A plain edit of the archived user is not a reactivation.
      put "/users/#{archived.id}", params: { user: { first_name: 'Renamed' } }

      expect(response).to have_http_status(:redirect)
      expect(archived.reload).to have_attributes(first_name: 'Renamed')
      expect(archived.archived_at).to be_present

      two_seats = create(:account, :paid, seats: 2)
      parked = create(:user, account: two_seats, archived_at: 1.day.ago)
      act_as(two_seats)

      put "/users/#{parked.id}", params: { user: { archived_at: '' } }

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_nil
      expect(parked.reload.archived_at).to be_nil
      expect(Accounts.users_count(two_seats)).to eq(2)
    end
  end

  describe 'sending pause' do
    it 'pauses on a complaint, emails the admins, flags the account, blocks the link, and resumes cleanly',
       sidekiq: :inline do
      template = text_template_for(free_account, shared_link: true)
      submitter = send_one(free_account, template:).submitters.first
      event = create(:email_event, account: free_account, emailable: submitter, event_type: 'complaint',
                                   email: submitter.email)

      SendingPause.evaluate!(free_account, event:)

      expect(SendingPause.paused?(free_account)).to be(true)
      expect(free_account.reload.sending_pause_reason).to eq('complaint')
      expect(AbuseFlag.where(account: free_account, kind: 'complaint').count).to eq(1)

      pause_mail = deliveries.select { |m| m.subject == 'Sending is paused on your EsignCenter account' }

      expect(pause_mail.size).to eq(1)
      expect(pause_mail.sole.to).to eq([admin_for(free_account).email])
      expect(pause_mail.sole.body.encoded).to include('reported an email from this account as spam')

      anonymous!
      get "/d/#{template.slug}"

      expect(response.body).to include(signer_page)

      act_as(free_account)

      refusing { post_recipients(template, emails: unique_email, send_email: '1') }

      expect(flash[:alert]).to eq(paused_alert)

      complete!(submitter)

      expect(submitter.reload.completed_at).to be_present

      SendingPause.resume!(free_account)

      expect(SendingPause.paused?(free_account)).to be(false)
      expect(free_account.reload.sending_pause_reason).to be_nil
      expect(AbuseFlag.where(account: free_account, kind: 'complaint').open).not_to exist

      anonymous!
      get "/d/#{template.slug}"

      expect(response.body).not_to include(signer_page)
    end

    it 'records one flag and one mail for repeated complaints, and reopens the flag after a resume',
       sidekiq: :inline do
      submitter = send_one(free_account).submitters.first
      pause_subject = 'Sending is paused on your EsignCenter account'
      complaint = lambda do
        create(:email_event, account: free_account, emailable: submitter, event_type: 'complaint',
                             email: submitter.email)
      end

      SendingPause.evaluate!(free_account, event: complaint.call)
      SendingPause.evaluate!(free_account, event: complaint.call)

      expect(SendingPause.paused?(free_account)).to be(true)
      expect(AbuseFlag.where(account: free_account, kind: 'complaint').count).to eq(1)
      expect(deliveries.count { |m| m.subject == pause_subject }).to eq(1)

      SendingPause.resume!(free_account)

      expect(SendingPause.paused?(free_account)).to be(false)
      expect(AbuseFlag.where(account: free_account, kind: 'complaint').open).not_to exist

      SendingPause.evaluate!(free_account, event: complaint.call)

      expect(SendingPause.paused?(free_account)).to be(true)
      expect(AbuseFlag.where(account: free_account, kind: 'complaint').count).to eq(1)
      expect(AbuseFlag.where(account: free_account, kind: 'complaint').open.count).to eq(1)
      expect(deliveries.count { |m| m.subject == pause_subject }).to eq(2)
    end

    it 'pauses on bounce rate only once ten deliveries are in the window and a fifth of them bounced' do
      submitter = send_one(free_account).submitters.first

      # A delivery is one (message, recipient) pair.
      record = lambda do |account, type, message_id: SecureRandom.uuid, email: submitter.email, minutes_ago: 0|
        create(:email_event, account:, emailable: submitter, event_type: type, message_id:, email:,
                             event_datetime: minutes_ago.minutes.ago)
      end

      sent = Array.new(9) { |i| record.call(free_account, 'send', minutes_ago: 9 - i).message_id }
      bounce = record.call(free_account, 'bounce', message_id: sent[0])
      record.call(free_account, 'bounce', message_id: sent[1])

      SendingPause.evaluate!(free_account, event: bounce)

      expect(SendingPause.paused?(free_account)).to be(false)

      record.call(free_account, 'send')
      SendingPause.evaluate!(free_account, event: bounce)

      expect(SendingPause.paused?(free_account)).to be(true)
      expect(free_account.reload.sending_pause_reason).to eq('bounce_rate')
      expect(AbuseFlag.where(account: free_account, kind: 'bounce_rate').count).to eq(1)

      other = create(:account)
      other_sent = Array.new(10) { |i| record.call(other, 'send', minutes_ago: 10 - i).message_id }
      other_bounce = record.call(other, 'bounce', message_id: other_sent[0])

      SendingPause.evaluate!(other, event: other_bounce)

      expect(SendingPause.paused?(other)).to be(false)

      # One message to ten recipients is ten deliveries: two of them bouncing
      # is a fifth, even though there is only one message id.
      team = create(:account)
      message_id = SecureRandom.uuid
      recipients = Array.new(10) { unique_email }
      recipients.each_with_index { |email, i| record.call(team, 'send', message_id:, email:, minutes_ago: 10 - i) }
      record.call(team, 'bounce', message_id:, email: recipients[0])
      team_bounce = record.call(team, 'bounce', message_id:, email: recipients[1])

      SendingPause.evaluate!(team, event: team_bounce)

      expect(SendingPause.paused?(team)).to be(true)
      expect(team.reload.sending_pause_reason).to eq('bounce_rate')
    end

    it 'counts a message sent twice to the same address as one delivery, so duplicates never shrink the window' do
      submitter = send_one(free_account).submitters.first
      team = create(:account)
      record = lambda do |type, message_id: SecureRandom.uuid, email: unique_email, minutes_ago: 0|
        create(:email_event, account: team, emailable: submitter, event_type: type, message_id:, email:,
                             event_datetime: minutes_ago.minutes.ago)
      end

      # 19 older deliveries, the four oldest bounced; then one message whose
      # recipient is on it five times (to + cc). 24 send events, 20 distinct
      # deliveries: the window holds every one of them, so the bounced four
      # are inside it (4 of 20). Cutting 20 EVENTS instead would drop the
      # four oldest deliveries — exactly the bounced ones — and see 0 of 16.
      older = Array.new(19) { |i| record.call('send', minutes_ago: 60 - i) }
      older.first(4).each { |event| record.call('bounce', message_id: event.message_id, email: event.email) }
      duplicated = SecureRandom.uuid
      twice = unique_email
      5.times { record.call('send', message_id: duplicated, email: twice, minutes_ago: 1) }

      expect(SendingPause.bounce_rate(team)).to eq(0.2)

      SendingPause.evaluate!(team, event: EmailEvent.where(account: team, event_type: 'bounce').first)

      expect(SendingPause.paused?(team)).to be(true)
      expect(team.reload.sending_pause_reason).to eq('bounce_rate')
    end

    it 'sees a pause written by another connection after the account object was loaded' do
      stale = Account.find(free_account.id)

      expect(SendingPause.paused?(stale)).to be(false)

      Account.where(id: free_account.id).update_all(sending_paused_at: Time.current, sending_pause_reason: 'complaint')

      expect(stale.sending_paused_at).to be_nil
      expect(SendingPause.paused?(stale)).to be(true)
      expect { Quotas.assert_can_create_submissions!(stale) }
        .to raise_error(Quotas::LimitReached) { |e| expect(e.reason).to eq(:sending_paused) }

      SendingPause.resume!(stale)

      expect(SendingPause.paused?(stale)).to be(false)
      expect(free_account.reload.sending_pause_reason).to be_nil
    end
  end

  describe 'linked and testing children' do
    it 'rolls a testing child up to the parent limits and lets a linked child inherit a paid parent',
       sidekiq: :inline do
      admin_for(free_account)
      testing_user = Accounts.find_or_create_testing_user(free_account)
      child = testing_user.account
      child_template = create(:template, account: child, author: testing_user, only_field_types: %w[text])

      Submissions.create_from_emails(template: child_template, user: testing_user, emails: unique_email,
                                     source: :invite, mark_as_sent: true)

      expect(Quotas.sends_this_month(free_account)).to eq(1)
      expect(Quotas.sends_this_month(child)).to eq(1)
      expect(Quotas.in_flight(free_account)).to eq(1)

      cap_completions!(free_account)

      sign_out(:user)
      reset!
      sign_in(testing_user)

      refusing { post "/templates/#{child_template.id}/submissions", params: { emails: unique_email, send_email: '1' } }

      expect(flash[:alert]).to eq(completions_alert)

      linked = create(:account)
      AccountLinkedAccount.create!(account: paid_account, linked_account: linked, account_type: 'linked')

      expect(Plans.key_for(linked)).to eq(Plans::PAID)
      expect(Quotas.limits_for(linked).completions_per_month).to be_nil

      complete_one!(linked)

      expect(Quotas.completions_this_month(paid_account)).to eq(1)
      expect(Quotas.completions_this_month(linked)).to eq(1)
    end
  end
end

# Concurrency needs real, committed transactions: two connections racing for
# the last send must serialise on the advisory lock, so this block runs
# without the wrapping test transaction and cleans up after itself. It is a
# separate top-level group on purpose: nested under the one above it would
# inherit the `let!` accounts and the platform certificate row, which would
# then be committed for real and leak into every later example.
RSpec.describe 'Quota creation lock', type: :request do
  self.use_transactional_tests = false

  it 'lets exactly one of two concurrent creators through at 14 sends' do
    account = create(:account)
    user = create(:user, account:)
    template = create(:template, account:, author: user, only_field_types: %w[text])

    seed = ->(i) { Submissions.create_from_emails(template:, user:, emails: "seed-#{i}@example.com", source: :invite) }
    # Free accounts hold at most 10 open documents: five are deleted on the
    # way to 14 sends, so the race is decided by the send cap alone.
    seeds = Array.new(10) { |i| seed.call(i).sole }
    seeds.first(5).each { |submission| submission.update!(archived_at: Time.current) }
    4.times { |i| seed.call(10 + i) }

    expect(Quotas.sends_this_month(account)).to eq(14)
    expect(Quotas.in_flight(account)).to eq(9)

    barrier = Queue.new
    results = Array.new(2) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop

          Submissions.create_from_emails(template: Template.find(template.id), user: User.find(user.id),
                                         emails: "race-#{i}@example.com", source: :invite)
          :created
        rescue Quotas::LimitReached => e
          e.reason
        end
      end
    end

    2.times { barrier << true }

    outcomes = results.map(&:value)

    expect(outcomes.sort_by(&:to_s)).to eq(%i[created sends])
    expect(Quotas.sends_this_month(account)).to eq(15)
    expect(Submission.where(account_id: account.id).count).to eq(15)
  ensure
    account&.destroy!
  end

  it 'lets exactly one of two concurrent invites fill the last seat' do
    account = create(:account, :paid, seats: 2)
    admin = create(:user, account:)

    # Two signed-in browser sessions of the same admin, each with its own
    # cookie jar; the sign-in itself happens one at a time.
    sessions = Array.new(2) do
      session = open_session
      sign_in(admin)
      session.get('/')
      session
    end

    barrier = Queue.new
    results = sessions.map.with_index do |session, i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop

          session.post('/users', params: { user: { email: "seat-race-#{i}@example.com", first_name: 'New',
                                                   last_name: 'Person', role: 'admin' } })

          session.flash[:alert].presence || :invited
        end
      end
    end

    2.times { barrier << true }

    outcomes = results.map(&:value)

    expect(outcomes.sort_by(&:to_s)).to eq([I18n.t('seat_limit_paid', count: 2), :invited])
    expect(User.where(account_id: account.id).count).to eq(2)
    expect(User.where(email: %w[seat-race-0@example.com seat-race-1@example.com]).count).to eq(1)
  ensure
    account&.destroy!
  end
end
