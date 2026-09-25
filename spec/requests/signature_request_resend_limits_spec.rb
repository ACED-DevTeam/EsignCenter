# frozen_string_literal: true

# One document used to buy unlimited signing-request email (launch security
# review, finding 2): `PUT /api/submitters/:id` with `send_email` (reachable
# with the browser session, so the free plan's API-token block never
# applied), the HTML address change, and a signer's delegation all mailed
# again on every call. Every such door now goes through
# Submitters::ResendGuard, and a paused account sends no signing request at
# all.
RSpec.describe 'Signing-request resend limits', type: :request do
  let(:free_account) { create(:account) }
  let(:paid_account) { create(:account, :paid) }
  let(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }
  let(:json_headers) { { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' } }
  let(:tomorrow) { Time.current.utc.beginning_of_day.tomorrow.strftime('%Y-%m-%d') }
  let(:signer_limit) { Quotas::Limits::RESENDS_PER_SIGNER_PER_DAY }
  let(:signer_alert) { I18n.t('quota_reached_signer_resends', limit: signer_limit, date: tomorrow) }
  let(:free_day_alert) do
    I18n.t('quota_reached_resends', limit: Quotas::Limits::FREE_RESENDS_PER_DAY, date: tomorrow)
  end
  let(:deliveries) { ActionMailer::Base.deliveries }

  before do
    platform_certificate!
    deliveries.clear
    Sidekiq::Worker.clear_all
  end

  def admin_for(account)
    admins[account.id] ||= create(:user, account:)
  end

  def send_one(account)
    template = create(:template, account:, author: admin_for(account), only_field_types: %w[text])

    Submissions.create_from_emails(template:, user: admin_for(account), source: :invite, mark_as_sent: true,
                                   emails: "signer-#{SecureRandom.hex(4)}@example.com").sole.submitters.sole
  end

  def invitation_jobs
    SendSubmitterInvitationEmailJob.jobs
  end

  def pause!(account)
    account.update!(sending_paused_at: Time.current, sending_pause_reason: 'complaint')
  end

  def api_resend(submitter, email: "next-#{SecureRandom.hex(4)}@example.com")
    put "/api/submitters/#{submitter.id}", params: { email:, send_email: true }.to_json, headers: json_headers
  end

  describe 'PUT /api/submitters/:id with send_email, on the browser session' do
    it 'emails one signer at most the per-signer number a day, whatever the address' do
      submitter = send_one(free_account)
      sign_in(admin_for(free_account))

      signer_limit.times do
        api_resend(submitter)

        expect(response).to have_http_status(:ok)
      end

      expect(invitation_jobs.size).to eq(signer_limit)
      address_before = submitter.reload.email

      api_resend(submitter, email: 'one-more@example.com')

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body['error']).to eq(I18n.t('quota_reached_signer_resends', locale: :en,
                                                                                         limit: signer_limit,
                                                                                         date: tomorrow))
      expect(invitation_jobs.size).to eq(signer_limit)
      # Refused before anything was written.
      expect(submitter.reload.email).to eq(address_before)
    end

    it 'stops a free account at its daily number of resends across every signer' do
      signers = Array.new(7) { send_one(free_account) }
      sign_in(admin_for(free_account))
      statuses = []

      signers.each do |signer|
        signer_limit.times do
          api_resend(signer)
          statuses << response.status
        end
      end

      expect(statuses.count(200)).to eq(Quotas::Limits::FREE_RESENDS_PER_DAY)
      expect(statuses.last).to eq(429)
      expect(response.parsed_body['error']).to eq(I18n.t('quota_reached_resends', locale: :en,
                                                                                  limit: Quotas::Limits::FREE_RESENDS_PER_DAY,
                                                                                  date: tomorrow))
      expect(invitation_jobs.size).to eq(Quotas::Limits::FREE_RESENDS_PER_DAY)
      expect(Submitters::ResendGuard.resends_today(free_account)).to be > Quotas::Limits::FREE_RESENDS_PER_DAY
    end

    it 'never blocks a paid account for volume, but raises a resend-velocity review flag' do
      stub_const('Quotas::Limits::PAID_RESENDS_PER_DAY_PER_SEAT', 1)
      signers = Array.new(2) { send_one(paid_account) }
      sign_in(admin_for(paid_account))

      signers.each do |signer|
        api_resend(signer)

        expect(response).to have_http_status(:ok)
      end

      expect(invitation_jobs.size).to eq(2)
      flag = AbuseFlag.find_by!(account: paid_account, kind: 'resend_velocity')
      expect(flag.details).to include('resends_today' => 2, 'seats' => 1)
    end

    it 'refuses every resend while the account is sending-paused, paid included' do
      submitter = send_one(paid_account)
      pause!(paid_account)
      sign_in(admin_for(paid_account))

      api_resend(submitter)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq(I18n.t('sending_paused_alert', locale: :en))
      expect(invitation_jobs).to be_empty
    end

    it 'leaves internal accounts unthrottled' do
      submitter = send_one(internal_account)
      sign_in(admin_for(internal_account))

      (signer_limit + 1).times do
        api_resend(submitter)

        expect(response).to have_http_status(:ok)
      end

      expect(invitation_jobs.size).to eq(signer_limit + 1)
    end
  end

  describe 'PUT /submitters/:id (the dashboard address change)' do
    def change_address(submitter, email)
      patch submitter_path(submitter), params: { submitter: { email: }, send_email: '1' }
    end

    it 'revokes the old signing link and counts every changed address against the same signer' do
      submitter = send_one(free_account)
      sign_in(admin_for(free_account))
      old_slug = submitter.slug

      change_address(submitter, 'first-fix@example.com')

      expect(flash[:notice]).to eq(I18n.t('changes_have_been_saved'))
      expect(submitter.reload.slug).not_to eq(old_slug)
      expect(Submitter.find_by(slug: old_slug)).to be_nil

      (signer_limit - 1).times { |i| change_address(submitter, "fix-#{i}@example.com") }

      expect(invitation_jobs.size).to eq(signer_limit)

      change_address(submitter, 'too-many@example.com')

      expect(flash[:alert]).to eq(signer_alert)
      expect(submitter.reload.email).not_to eq('too-many@example.com')
      expect(invitation_jobs.size).to eq(signer_limit)
    end

    it 'refuses the resend while sending is paused' do
      submitter = send_one(free_account)
      pause!(free_account)
      sign_in(admin_for(free_account))

      change_address(submitter, 'fix@example.com')

      expect(flash[:alert]).to eq(I18n.t('sending_paused_alert'))
      expect(submitter.reload.email).not_to eq('fix@example.com')
      expect(invitation_jobs).to be_empty
    end
  end

  describe 'the resend buttons' do
    # "Resend to all" (SubmissionsResendEmailController) goes through the same
    # guard, but no ability grants `:resend_all` in this fork, so it is not
    # reachable to exercise here.
    it 'refuses "send email" while the account is sending-paused, paid included' do
      submitter = send_one(paid_account)
      pause!(paid_account)
      sign_in(admin_for(paid_account))

      post submitter_send_email_index_path(submitter_id: submitter.id)

      expect(flash[:alert]).to eq(I18n.t('sending_paused_alert'))
      expect(invitation_jobs).to be_empty
    end

    it 'stops "send email" at the free daily cap' do
      signers = Array.new(Quotas::Limits::FREE_IN_FLIGHT) { send_one(free_account) }
      sign_in(admin_for(free_account))

      (Quotas::Limits::FREE_RESENDS_PER_DAY / signer_limit).times do |i|
        signer_limit.times { api_resend(signers[i]) }
      end
      (Quotas::Limits::FREE_RESENDS_PER_DAY % signer_limit).times { api_resend(signers.last) }

      post submitter_send_email_index_path(submitter_id: signers[-2].id)

      expect(flash[:alert]).to eq(free_day_alert)
      expect(invitation_jobs.size).to eq(Quotas::Limits::FREE_RESENDS_PER_DAY)
    end
  end

  describe 'a signer delegating the document' do
    before do
      create(:account_config, account: free_account, key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)
    end

    it 'lets one signer hand the document on only the per-signer number of times a day' do
      submitter = send_one(free_account)

      signer_limit.times do |i|
        post submit_form_delegate_index_path(submitter.reload.slug), params: { email: "delegate-#{i}@example.com" }

        expect(response).to redirect_to(%r{/delegated})
      end

      post submit_form_delegate_index_path(submitter.reload.slug), params: { email: 'loop@example.com' }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('this_document_cannot_be_delegated_right_now')))
      expect(submitter.reload.email).to eq("delegate-#{signer_limit - 1}@example.com")
      expect(invitation_jobs.size).to eq(signer_limit)
    end
  end

  describe 'the invitation job itself' do
    it 'sends no signing request of any kind while the account is sending-paused' do
      allow(Accounts).to receive(:can_send_emails?).and_return(true)
      delivered = send_one(free_account)
      held = send_one(free_account)

      SendSubmitterInvitationEmailJob.new.perform('submitter_id' => delivered.id)

      expect(deliveries.size).to eq(1)

      pause!(free_account)

      SendSubmitterInvitationEmailJob.new.perform('submitter_id' => held.id)

      expect(deliveries.size).to eq(1)
      expect(SubmissionEvent.where(submitter: held, event_type: 'send_email')).not_to exist
    end
  end
end
