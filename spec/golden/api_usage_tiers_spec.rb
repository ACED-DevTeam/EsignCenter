# frozen_string_literal: true

# D79 shares the real first-signer pipeline with the ordinary quota suite.
# No completion rows are inserted here: sources and lineage are captured by
# ProcessSubmitterCompletionJob after the signer's consent-bearing request.
RSpec.describe 'API usage tiers', type: :request do
  let(:account) { create(:account, :paid) }
  let(:admin) { create(:user, account:) }
  let(:template) { template_for(account, admin) }
  let(:headers) { { 'x-auth-token' => admin.access_token.token, 'CONTENT_TYPE' => 'application/json' } }

  before do
    platform_certificate!
    ActionMailer::Base.deliveries.clear
  end

  def template_for(owner, author, submitter_count: 1)
    create(:template, account: owner, author:, attachment_count: 0, submitter_count:, shared_link: true,
                      preferences: { 'completed_notification_email_enabled' => false,
                                     'documents_copy_email_enabled' => false }).tap do |record|
      record.update!(fields: record.submitters.map do |role|
        { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => role['uuid'], 'name' => 'Name',
          'type' => 'text', 'required' => true, 'areas' => [] }
      end)
    end
  end

  def send_document(source: :api, record: template, user: admin)
    attrs = record.submitters.map { |role| { uuid: role['uuid'], email: "#{SecureRandom.hex(5)}@example.com" } }
    Submissions.create_from_submitters(template: record, user:, source:, submitters_order: 'random',
                                       params: { send_email: false },
                                       submissions_attrs: [{ submitters: attrs }.with_indifferent_access]).sole
  end

  def reach_allowance!
    AccountLimitOverride.create!(account:, api_completions_per_month: 1)
    complete!(send_document.submitters.first)
  end

  def request_attrs
    { template_id: template.id, submitters: [{ email: 'new@example.com' }], send_email: false }
  end

  describe 'allowances' do
    it 'gives Paid 50 and Business 500 per billing account, with 50 per pack and trial access' do
      row = account.account_subscription
      row.update!(quantity: 8)
      expect(Quotas.limits_for(account).api_completions_per_month).to eq(50)

      row.update!(plan: Plans::BUSINESS, access_state: 'trialing', api_pack_quantity: 2)
      expect(Plans.key_for(account)).to eq(Plans::BUSINESS)
      expect(Plans.paid_or_better?(account)).to be(true)
      expect(Quotas.limits_for(account).api_completions_per_month).to eq(600)
      expect(Quotas.limits_for(account).seats).to eq(8)
    end

    it 'retains removed packs until renewal and drops the retained allowance at renewal' do
      account.account_subscription.update!(api_pack_quantity: 1, retained_api_pack_quantity: 3,
                                           retained_api_pack_until: 1.day.from_now)
      expect(Quotas.limits_for(account).api_completions_per_month).to eq(200)

      travel 2.days do
        expect(Quotas.limits_for(account).api_completions_per_month).to eq(100)
      end
    end

    it 'lets operators set a cap or unlimited while internal/operator accounts stay exempt' do
      override = AccountLimitOverride.create!(account:, api_completions_per_month: 975)
      expect(Quotas.limits_for(account).api_completions_per_month).to eq(975)
      override.update!(api_completions_per_month: -1)
      expect(Quotas.limits_for(account.reload).api_completions_per_month).to be_nil
      override.update!(api_completions_per_month: nil)
      expect(Quotas.limits_for(account.reload).api_completions_per_month).to eq(50)

      %i[internal operator].each do |kind|
        exempt = create(:account, kind)
        AccountLimitOverride.create!(account: exempt, api_completions_per_month: 0)
        expect(Quotas.limits_for(exempt).api_completions_per_month).to be_nil
        expect(Quotas.assert_can_create_submissions!(exempt, source: :api)).to be(true)
      end
      expect(Quotas.limits_for(create(:account)).api_completions_per_month).to eq(0)
    end
  end

  describe 'first-signer metering', sidekiq: :inline do
    it 'counts api/embed/mcp and excludes invite/link/bulk, preserving usage after deletion' do
      %i[api embed mcp invite link bulk].each { |source| complete!(send_document(source:).submitters.first) }
      expect(Quotas.api_completions_this_month(account)).to eq(3)
      expect(Quotas.completions_this_month(account)).to eq(6)

      account.submissions.destroy_all
      expect(Quotas.api_completions_this_month(account)).to eq(3)
    end

    it 'counts once for two signers, a repeated completion job, and a corrected lineage' do
      two_signers = template_for(account, admin, submitter_count: 2)
      original = send_document(record: two_signers)
      first, second = original.submitters.order(:id)
      complete!(first)
      expect(Quotas.api_completions_this_month(account)).to eq(1)
      complete!(second)
      ProcessSubmitterCompletionJob.new.perform('submitter_id' => first.id)
      expect(Quotas.api_completions_this_month(account)).to eq(1)

      copy = send_document
      copy.update!(**Submissions::Lineage.attributes_for_copy(original))
      complete!(copy.submitters.first)
      expect(Quotas.api_completions_this_month(account)).to eq(1)
    end

    it 'counts an unsigned lineage once and rolls a child account up to its billing account' do
      child = create(:account)
      account.testing_accounts << child
      child_admin = create(:user, account: child)
      child_template = template_for(child, child_admin)
      original = send_document(record: child_template, user: child_admin)
      copy = send_document(record: child_template, user: child_admin)
      copy.update!(**Submissions::Lineage.attributes_for_copy(original))
      complete!(copy.submitters.first)
      complete!(original.submitters.first)
      expect(Quotas.api_completions_this_month(account)).to eq(1)
      expect(Quotas.api_completions_this_month(child)).to eq(1)
      expect(Quotas.limits_for(child).api_completions_per_month).to eq(50)
    end

    it 'counts only the current UTC month' do
      travel_to Time.utc(2026, 9, 30, 23, 59) do
        complete!(send_document.submitters.first)
        expect(Quotas.api_completions_this_month(account)).to eq(1)
      end
      travel_to Time.utc(2026, 10, 1) do
        expect(Quotas.api_completions_this_month(account)).to eq(0)
      end
    end
  end

  describe 'creation refusal', sidekiq: :inline do
    before { reach_allowance! }

    it 'refuses every API submission route and both email and role payloads with actionable 402 JSON' do
      ['/api/submissions', '/api/submissions/init', '/api/submissions/emails',
       "/api/templates/#{template.id}/submissions"].each do |path|
        [request_attrs, { template_id: template.id, emails: 'new@example.com' }].each do |attrs|
          expect { post path, headers:, params: attrs.to_json }.not_to change(Submission, :count)
          expect(response).to have_http_status(:payment_required), path
          expect(response.parsed_body['error']).to include('1', Quotas.resets_at.strftime('%Y-%m-%d'),
                                                           '/settings/billing')
        end
      end
    end

    it 'refuses signing sessions for templates and inline documents before storing blobs' do
      pdf = Base64.encode64(Rails.root.join('spec/fixtures/sample-document.pdf').read)
      inline = { name: 'Inline', documents: [{ name: 'contract.pdf',
                                               file: pdf }],
                 submitters: [{ name: 'Borrower', email: 'new@example.com' }],
                 fields: [{ name: 'Name', type: 'text', role: 'Borrower',
                            areas: [{ x: 0.1, y: 0.8, w: 0.3, h: 0.06, page: 0, document: 0 }] }] }
      allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
      [request_attrs, inline].each do |attrs|
        expect do
          post '/api/signing_sessions', headers:,
                                        params: attrs.merge(embed_origin: 'https://app.example.com').to_json
        end.not_to change(Submission, :count)
        expect(response).to have_http_status(:payment_required)
      end
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'refuses MCP send_documents with its ordinary JSON tool error' do
      token = admin.mcp_tokens.create!(name: 'API tiers')
      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)
      call = { name: 'send_documents', arguments: request_attrs.except(:send_email) }
      expect do
        post '/mcp', headers: { 'Authorization' => "Bearer #{token.token}", 'CONTENT_TYPE' => 'application/json' },
                     params: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: call }.to_json
      end.not_to change(Submission, :count)
      expect(response.parsed_body.dig('result', 'isError')).to be(true)
      expect(response.parsed_body.dig('result', 'content').sole['text']).to include('/settings/billing')
    end

    it 'resumes signing-session creation immediately after a pack purchase and at UTC rollover' do
      account.limit_override.update!(api_completions_per_month: nil)
      stub_const('Quotas::Limits::PAID_API_COMPLETIONS_PER_MONTH', 1)
      expect(Quotas.share_link_paused?(account.reload, source: :embed)).to eq(:api_completions)
      account.account_subscription.update!(api_pack_quantity: 1)
      expect(Quotas.share_link_paused?(account.reload, source: :embed)).to be_nil
      account.account_subscription.update!(api_pack_quantity: 0)
      travel_to Quotas.resets_at do
        expect(Quotas.share_link_paused?(account.reload, source: :embed)).to be_nil
      end
    end

    it 'keeps in-app sending, public links and signed-lineage corrections open at the API cap' do
      expect { send_document(source: :invite) }.to change(Submission, :count).by(1)
      expect { send_document(source: :bulk) }.to change(Submission, :count).by(1)
      get "/d/#{template.slug}"
      expect(response.body).not_to include(I18n.t('form_not_accepting_responses'))
      expect(response.headers['X-Frame-Options']).to eq('SAMEORIGIN')

      expect do
        put "/d/#{template.slug}", params: { submitter: { email: 'in-app-link@example.com' } }
      end.to change(Submission, :count).by(1)
      expect(Submission.order(:id).last.source).to eq('link')

      original = account.submissions.find_by!(source: :api).submitters.first
      expect(Quotas.assert_can_create_submissions!(account, source: :api,
                                                            correction_of: original.submission)).to be(true)
      expect { put '/resubmit_form', params: { resubmit: original.slug } }.to change(Submission, :count).by(1)
      expect(Submission.order(:id).last.source).to eq('link')
      expect(response).to have_http_status(:redirect)
    end
  end

  it 'lets documents sent before the allowance was reached finish', sidekiq: :inline do
    in_flight = send_document
    finishing = send_document
    AccountLimitOverride.create!(account:, api_completions_per_month: 1)
    complete!(finishing.submitters.first)
    complete!(in_flight.submitters.first)
    expect(Quotas.api_completions_this_month(account)).to eq(2)
  end

  describe 'creation reservations' do
    it 'refuses a whole batch that crosses 50, admits the final open document and refuses the next' do
      49.times { send_document }
      expect(Quotas.api_completions_this_month(account)).to eq(0)
      expect(Quotas.api_reservations(account)).to eq(49)
      attrs = { template_id: template.id, emails: 'one@example.com,two@example.com', send_email: false }
      expect { post '/api/submissions', headers:, params: attrs.to_json }.not_to change(Submission, :count)
      expect(response).to have_http_status(:payment_required)
      expect { send_document }.to change(Submission, :count).by(1)
      expect { send_document }.to raise_error(Quotas::LimitReached)
      expect(Quotas.api_capacity_used(account)).to eq(50)
    end

    it 'releases reservations when documents decline, expire, archive or are deleted' do
      AccountLimitOverride.create!(account:, api_completions_per_month: 1)
      %i[decline expire archive delete].each do |action|
        document = send_document
        expect(Quotas.api_reservations(account)).to eq(1)
        case action
        when :decline then document.submitters.first.update!(declined_at: Time.current)
        when :expire then document.update!(expire_at: 1.second.ago)
        when :archive then document.update!(archived_at: Time.current)
        when :delete then document.destroy!
        end
        expect(Quotas.api_reservations(account)).to eq(0)
      end
      expect { send_document }.to change(Submission, :count).by(1)
    end

    it 'counts the first completion once while a second signer is pending, and never reserves a counted correction',
       sidekiq: :inline do
      AccountLimitOverride.create!(account:, api_completions_per_month: 2)
      document = send_document(record: template_for(account, admin, submitter_count: 2))
      complete!(document.submitters.order(:id).first)
      expect(document.submitters.where(completed_at: nil).count).to eq(1)
      expect(Quotas.api_reservations(account)).to eq(0)
      expect(Quotas.api_capacity_used(account)).to eq(1)
      copy = send_document
      copy.update!(**Submissions::Lineage.attributes_for_copy(document))
      expect(Quotas.api_capacity_used(account)).to eq(1)
      expect { send_document }.to change(Submission, :count).by(1)
    end

    it 'holds the reservation while the async completion job is still pending' do
      document = send_document
      document.submitters.first.update!(completed_at: Time.current)
      expect(Quotas.api_completions_this_month(account)).to eq(0)
      expect(Quotas.api_reservations(account)).to eq(1)
    end

    it 'never API-blocks an in-app resubmit of an unsigned document' do
      document = send_document
      document.submitters.first.update!(email: admin.email)
      AccountLimitOverride.create!(account:, api_completions_per_month: 0)
      sign_in(admin)
      expect { put "/submitters_resubmit/#{document.submitters.first.id}" }.to change(Submission, :count).by(1)
      expect(response).to have_http_status(:redirect)
      expect(Submission.order(:id).last.source).to eq('link')
    end
  end

  describe 'rollout activation', sidekiq: :inline do
    it 'keeps a deployment timestamp across repeated reads instead of resetting it at process start' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('API_METERING_STARTS_AT').and_return(nil)
      activated_at = ApiMeteringActivation.starts_at
      travel 1.hour do
        expect(ApiMeteringActivation.starts_at).to eq(activated_at)
      end
    end

    it 'excludes old open documents and late completions, and preserves new usage after deletion' do
      activation = Time.current.change(usec: 0)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('API_METERING_STARTS_AT').and_return(activation.iso8601)
      old = travel_to(activation - 1.day) { send_document }
      pending_old = travel_to(activation - 1.day) { send_document }
      AccountLimitOverride.create!(account:, api_completions_per_month: 1)
      complete!(old.submitters.first)
      expect(Quotas.api_completions_this_month(account)).to eq(0)
      expect(Quotas.api_reservations(account)).to eq(0)
      expect(pending_old.submitters.first.completed_at).to be_nil
      fresh = send_document
      expect(Quotas.api_reservations(account)).to eq(1)
      complete!(fresh.submitters.first)
      fresh.destroy!
      expect(Quotas.api_completions_this_month(account)).to eq(1)
      account.reload
      template.reload
      expect { send_document }.to raise_error(Quotas::LimitReached)
    end

    it 'does not warn for pre-activation documents that finish afterwards' do
      activation = Time.current.change(usec: 0)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('API_METERING_STARTS_AT').and_return(activation.iso8601)
      old = travel_to(activation - 1.day) { send_document }
      AccountLimitOverride.create!(account:, api_completions_per_month: 1)
      complete!(old.submitters.first)
      expect(ActionMailer::Base.deliveries.map(&:subject).grep(/^API completions:/)).to be_empty
    end
  end

  it 'does not send API usage warnings when an operator disables automation with a zero cap', sidekiq: :inline do
    AccountLimitOverride.create!(account:, api_completions_per_month: 0)
    complete!(send_document(source: :invite).submitters.first)
    expect(ActionMailer::Base.deliveries.map(&:subject).grep(/^API completions:/)).to be_empty
  end

  it 'warns once at 80% and 100%, independently of completion retries and pack changes', sidekiq: :inline do
    stub_const('Quotas::Limits::PAID_API_COMPLETIONS_PER_MONTH', 5)
    stub_const('Quotas::Limits::API_PACK_COMPLETIONS_PER_MONTH', 1)
    4.times { complete!(send_document.submitters.first) }
    subjects = -> { ActionMailer::Base.deliveries.map(&:subject).grep(/^API completions:/) }
    expect(subjects.call).to eq(['API completions: 80% of your monthly allowance used'])
    complete!(send_document.submitters.first)
    account.account_subscription.update!(api_pack_quantity: 1)
    complete!(send_document.submitters.first)
    2.times { Quotas.after_first_completion(account) }
    expect(subjects.call).to contain_exactly('API completions: 80% of your monthly allowance used',
                                             'API completions: 100% of your monthly allowance used')
    travel_to Quotas.resets_at do
      6.times { complete!(send_document.submitters.first) }
      expect(subjects.call.count('API completions: 80% of your monthly allowance used')).to eq(2)
      expect(subjects.call.count('API completions: 100% of your monthly allowance used')).to eq(2)
    end
  end
end
