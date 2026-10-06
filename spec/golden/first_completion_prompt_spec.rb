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

  # A metered completion row, written straight. The interactive signing path is
  # exercised by `complete_one!` above; the review-1 groups below are about what
  # the ARMING decision does once rows exist, so they write the rows the way a
  # parallel pair of signers leaves them and ask the question directly.
  def completion!(account, is_first:)
    template = create(:template, account:, author: admin_for(account), only_field_types: %w[text])
    submission = create(:submission, :with_submitters, template:, account:)

    CompletedSubmitter.create!(account:, submission:, submitter: submission.submitters.first, template:,
                               completed_at: Time.current, is_first:, sms_count: 0, source: 'invite')
  end

  def arm!(account)
    Quotas.after_first_completion(account, completion!(account, is_first: true))
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

  # --- review 1 regressions --------------------------------------------------

  describe 'arming it when completions land together (M1 / L1 / Codex 4)' do
    # The arming decision is taken AFTER the completion row is committed, so a
    # second row can already exist by the time the question is asked. These
    # write the rows the way a genuinely parallel pair of signers leaves them
    # and then ask, which is the race made deterministic — and the failure is
    # permanent, because the count only ever grows.
    it 'is not thrown away by the sibling signers of the account\'s own first document' do
      first = completion!(free_account, is_first: true)
      # The second signer of the SAME document: metered as a non-first row.
      completion!(free_account, is_first: false)

      Quotas.after_first_completion(free_account, first)

      expect(prompt_for(free_account)).to be_present
    end

    it 'arms exactly once when two documents finish at the same moment' do
      first = completion!(free_account, is_first: true)
      second = completion!(free_account, is_first: true)

      # Both rows are already committed, so neither caller can see itself as
      # "the only one". The earlier row is the first, whichever asks first.
      Quotas.after_first_completion(free_account, second)
      expect(prompt_for(free_account)).to be_nil

      Quotas.after_first_completion(free_account, first)
      expect(prompt_for(free_account)).to be_present

      expect { Quotas.after_first_completion(free_account, first) }
        .not_to(change { free_account.account_configs.count })
    end

    it 'arms the account that PAYS when the completion lands on a linked child' do
      child = create(:account,
                     linked_account_account: AccountLinkedAccount.new(account_type: :linked, account: free_account))
      create(:user, account: child)
      row = completion!(child, is_first: true)

      Quotas.after_first_completion(child, row)

      expect(prompt_for(free_account)).to be_present
      expect(prompt_for(child)).to be_nil
    end

    it 'still refuses an account that has finished documents before' do
      completion!(free_account, is_first: true)
      latest = completion!(free_account, is_first: true)

      Quotas.after_first_completion(free_account, latest)

      expect(prompt_for(free_account)).to be_nil
    end
  end

  describe 'a suspended or read-only account (L3)' do
    before { arm!(free_account) }

    it 'is not offered a banner it would not be allowed to dismiss' do
      AccountStates.suspend!(free_account, reason: 'billing')
      act_as(admin_for(free_account))

      get '/templates'

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(ERB::Util.html_escape(banner_title))
    end

    it 'is not offered to an administrator parked read-only' do
      parked = create(:user, account: free_account, read_only_at: Time.current)
      act_as(parked)

      get '/templates'

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(ERB::Util.html_escape(banner_title))
    end
  end

  describe 'the card it draws (M1 quality)' do
    # One upgrade card in the product, not two: the banner renders
    # shared/_upgrade_cta rather than a copy of its markup, so the next restyle
    # of that card reaches the dashboard too.
    let(:partial) { Rails.root.join('app/views/dashboard/_first_completion_prompt.html.erb').read }

    it 'renders the shared partial rather than a second copy of its markup' do
      expect(partial).to include("render 'shared/upgrade_cta'")
      expect(partial).not_to include('card bg-base-200')
      expect(partial).not_to include('svg_icon(\'sparkles\'')
    end

    it 'still draws the live upgrade button and the dismiss control' do
      arm!(free_account)
      act_as(admin_for(free_account))

      get '/templates'

      card = Nokogiri::HTML(response.body).at_css('[data-first-completion-prompt]')
      expect(card).to be_present
      # Billing where billing exists, the usage page otherwise: never a dead
      # link (shared/_upgrade_cta's own rule).
      expect(card.at_css('[data-upgrade-cta]')['href']).to be_in(['/settings/billing', Quotas::USAGE_PATH])
      expect(card.at_css("form[action='#{first_completion_prompt_path}']")).to be_present
      expect(card.at_css('[data-first-completion-dismiss]')).to be_present
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
