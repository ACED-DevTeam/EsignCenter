# frozen_string_literal: true

# The one-time upgrade nudge after a free account's very first signed document
# (D50): armed by the quota engine at the first counted completion, shown as a
# dismissible banner on both dashboards to that account's administrators, and
# never seen again once it is dismissed.
#
# Every completion here is a real one — a signer's PUT /s/:slug with consent
# under `sidekiq: :inline` — so the row is written the way production writes
# it, through ProcessSubmitterCompletionJob's lock.
RSpec.describe 'First completion upgrade prompt', type: :request do
  let(:free_account) { create(:account) }
  let(:paid_account) { create(:account, :paid) }
  let(:internal_account) { create(:account, :internal) }
  let(:admins) { {} }

  before { platform_certificate! }

  def admin_for(account)
    admins[account.id] ||= create(:user, account:)
  end

  def act_as(user)
    sign_out(:user)
    reset!
    sign_in(user)
  end

  def prompt_for(account)
    account.account_configs.find_by(key: AccountConfig::FIRST_COMPLETION_UPGRADE_PROMPT_KEY)
  end

  def complete_one!(account)
    template = create(:template, account:, author: admin_for(account), only_field_types: %w[text])
    submission = Submissions.create_from_emails(template:, user: admin_for(account),
                                                emails: "signer-#{SecureRandom.hex(4)}@example.com",
                                                source: :invite, mark_as_sent: true).sole

    complete!(submission.submitters.first)
  end

  def banner_title
    I18n.t('first_completion_prompt_title')
  end

  describe 'arming it' do
    it 'writes the row at the free account\'s first ever completion', sidekiq: :inline do
      expect { complete_one!(free_account) }.to change { prompt_for(free_account) }.from(nil)

      expect(prompt_for(free_account).value['shown_at']).to be_present
      expect(prompt_for(free_account).value['dismissed_at']).to be_nil
    end

    it 'does not rewrite it at the second completion', sidekiq: :inline do
      complete_one!(free_account)

      first = prompt_for(free_account)
      stamp = first.value['shown_at']

      travel_to(1.hour.from_now) { complete_one!(free_account) }

      expect(free_account.account_configs.where(key: AccountConfig::FIRST_COMPLETION_UPGRADE_PROMPT_KEY).count).to eq(1)
      expect(prompt_for(free_account).id).to eq(first.id)
      expect(prompt_for(free_account).value['shown_at']).to eq(stamp)
    end

    it 'never arms it for a paid account', sidekiq: :inline do
      complete_one!(paid_account)

      expect(prompt_for(paid_account)).to be_nil
    end

    # An internal account is exempt from metering, so the completion job never
    # even asks (spec/golden/quota_spec.rb). Asked anyway, the engine still
    # writes nothing: the arming lives in the free branch alone.
    it 'never arms it for an internal account' do
      Quotas.after_first_completion(internal_account)

      expect(prompt_for(internal_account)).to be_nil
      expect(internal_account.account_configs.count).to eq(0)
    end

    # D43: a downgrade does not hand the banner back — by then the account's
    # completion count is long past its first.
    it 'does not re-arm after a paid account drops back to free', sidekiq: :inline do
      complete_one!(paid_account)
      downgrade_to_free!(paid_account)

      complete_one!(paid_account)

      expect(prompt_for(paid_account)).to be_nil
    end

    # The banner must never be able to stop a signing: the completion job
    # swallows and reports anything the metering hook raises.
    it 'still delivers the completion when arming blows up', sidekiq: :inline do
      allow(Quotas).to receive(:arm_first_completion_prompt).and_raise(StandardError, 'boom')
      allow(ErrorReport).to receive(:error).and_call_original

      submitter = complete_one!(free_account)

      expect(submitter.completed_at).to be_present
      expect(submitter.documents).to be_present
      expect(ErrorReport).to have_received(:error).with(instance_of(StandardError), account_id: free_account.id)
    end
  end

  describe 'showing it' do
    before { complete_one!(free_account) }

    around { |example| Sidekiq::Testing.inline! { example.run } }

    it 'renders on both dashboards for an administrator, with a live upgrade link' do
      act_as(admin_for(free_account))

      get '/templates'
      expect(response.body).to include(ERB::Util.html_escape(banner_title))
      expect(response.body).to include(
        ERB::Util.html_escape(I18n.t('first_completion_prompt_body',
                                     limit: Quotas::Limits::FREE_COMPLETIONS_PER_MONTH))
      )
      expect(response.body).to include('data-upgrade-cta')

      get '/submissions'
      expect(response.body).to include(ERB::Util.html_escape(banner_title))
    end

    it 'does not render for a member who cannot buy anything' do
      act_as(create(:user, account: free_account, role: User::EDITOR_ROLE))

      get '/templates'

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(ERB::Util.html_escape(banner_title))
    end

    it 'does not render for an account that never earned it' do
      act_as(admin_for(paid_account))

      get '/templates'

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(ERB::Util.html_escape(banner_title))
    end
  end

  describe 'dismissing it' do
    before do
      Sidekiq::Testing.inline! { complete_one!(free_account) }
      act_as(admin_for(free_account))
    end

    it 'stamps the row and never shows the banner again' do
      delete first_completion_prompt_path

      expect(response).to have_http_status(:redirect)
      expect(prompt_for(free_account).value['dismissed_at']).to be_present
      expect(prompt_for(free_account).value['shown_at']).to be_present

      get '/templates'
      expect(response.body).not_to include(ERB::Util.html_escape(banner_title))

      get '/submissions'
      expect(response.body).not_to include(ERB::Util.html_escape(banner_title))
    end

    it 'refuses a member' do
      act_as(create(:user, account: free_account, role: User::EDITOR_ROLE))

      delete first_completion_prompt_path

      expect(response).to have_http_status(:redirect)
      expect(prompt_for(free_account).value['dismissed_at']).to be_nil
    end

    it 'writes no row when there was never a banner to dismiss' do
      act_as(admin_for(paid_account))

      expect { delete first_completion_prompt_path }.not_to change(AccountConfig, :count)
    end
  end
end
