# frozen_string_literal: true

# What happens to an account whose card keeps failing (D43/D57), and what
# deliberately does NOT.
#
# The rule this file protects: a suspended account is frozen for WRITES and
# nothing else. Everyone can still sign in, read, download and export; a
# signer already part-way through a document still finishes it and that
# completion is still metered; only creating and changing stops, on every
# door including the tokens. Paying lifts it by itself, within seconds.
#
# Archiving is the opposite policy and is asserted here too: archived means
# the account is gone, so the signer write paths stop as well.
#
# Every completion is a REAL one (a signer's PUT /s/:slug with consent,
# SigningHelpers#complete!) under `sidekiq: :inline`; no metering row is ever
# inserted by hand. Stripe is never called: the subscription states come from
# real CLI captures (spec/fixtures/stripe) fed to the ONE mapping every
# Stripe door shares (StripeBilling::SubscriptionSync.apply!).
RSpec.describe 'Account suspension', type: :request do # rubocop:disable RSpec/MultipleDescribes
  let(:account) { create(:account, :paid) }
  let(:admin) { create(:user, account:) }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before do
    platform_certificate!
    deliveries.clear
  end

  # A fresh integration session is the only reliable actor switch (see
  # spec/golden/gating_spec.rb).
  def act_as(user)
    sign_out(:user)
    reset!
    sign_in(user)
  end

  def anonymous!
    sign_out(:user)
    reset!
  end

  def unique_email
    "signer-#{SecureRandom.hex(4)}@example.com"
  end

  def suspend!(record = account, reason: 'billing')
    expect(AccountStates.suspend!(record, reason:)).to be(true)

    record.reload
  end

  def send_one(email: unique_email)
    Submissions.create_from_emails(template:, user: admin, emails: email, source: :invite,
                                   mark_as_sent: true).sole
  end

  describe 'what a suspended account can no longer do' do
    before do
      template
      suspend!
      act_as(admin)
    end

    it 'refuses a new template' do
      expect { post '/templates', params: { template: { name: 'While suspended' } } }
        .not_to change(Template, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to be_present
    end

    it 'refuses a change to an existing template' do
      expect { put "/templates/#{template.id}", params: { template: { name: 'Renamed' } } }
        .not_to(change { template.reload.name })

      expect(response).to redirect_to(root_path)
    end

    it 'refuses an invitation to a new person' do
      expect do
        post '/users', params: { user: { email: unique_email, first_name: 'New',
                                         last_name: 'Person', role: 'admin' } }
      end.not_to change(User, :count)

      expect(response).to redirect_to(root_path)
    end

    it 'refuses a new document from the recipients form, creating nothing' do
      expect do
        post "/templates/#{template.id}/submissions", params: { emails: unique_email, send_email: '1' }
      end.not_to change(Submission, :count)

      expect(response).to redirect_to(root_path)
    end

    it 'refuses a new webhook and a new MCP token' do
      expect { post '/settings/webhooks', params: { webhook_url: { url: 'https://example.com/hook' } } }
        .not_to change(WebhookUrl, :count)

      create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)

      expect { post '/settings/mcp', params: { mcp_token: { name: 'While suspended' } } }
        .not_to change(McpToken, :count)
    end

    # The chokepoint every non-CanCan creation path shares refuses too, with
    # its own sentence — so a door added later cannot forget the rule.
    it 'refuses at the quota chokepoint, on the paid plan, with the suspension message' do
      expect { Quotas.assert_can_create_submissions!(account) }
        .to raise_error(Quotas::LimitReached) { |e| expect(e.reason).to eq(:suspended) }

      expect(Quotas.share_link_paused?(account)).to eq(:suspended)
      expect(Quotas.message_for(:suspended)).to eq(I18n.t('account_suspended_alert'))
      expect(Quotas.pause_message(account, :suspended)).to eq(I18n.t('account_suspended_alert'))
    end

    it 'never refuses an internal account, whatever the state of its columns' do
      internal = create(:account, :internal)

      expect(AccountStates.suspend!(internal, reason: 'billing')).to be(false)
      expect(Quotas.assert_can_create_submissions!(internal)).to be(true)
    end
  end

  describe 'the share link of a suspended account' do
    before do
      template.update!(shared_link: true)
      suspend!
      anonymous!
    end

    it 'shows the ordinary closed page rather than a missing translation' do
      get "/d/#{template.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('form_not_accepting_responses'))
      expect(response.body).not_to include('translation missing')
    end

    it 'refuses the PUT that would start a document, creating nothing' do
      expect { put "/d/#{template.slug}", params: { submitter: { email: unique_email } } }
        .not_to change(Submission, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('form_not_accepting_responses'))
    end
  end

  describe 'what a suspended account can still do' do
    let!(:submission) { send_one }

    it 'reads the templates list and shows the banner with the way to fix it', sidekiq: :inline do
      suspend!
      act_as(admin)

      get '/templates'

      expect(response).to have_http_status(:ok)

      doc = Nokogiri::HTML(response.body)

      expect(doc.at('[data-account-suspended-banner]').text).to include(I18n.t('account_suspended_banner'))
      expect(doc.at('[data-account-suspended-link]')['href']).to eq('/settings/billing')
    end

    it 'downloads a completed document and exports the CSV', sidekiq: :inline do
      complete!(submission.submitters.first)
      suspend!
      act_as(admin)

      get "/submissions/#{submission.id}/download"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to be_present

      get "/templates/#{template.id}/submissions_export.csv"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(submission.submitters.first.email)
    end

    it 'lets an in-flight signer finish, and still meters the completion', sidekiq: :inline do
      submitter = submission.submitters.first
      suspend!
      anonymous!

      get "/s/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('form_has_been_archived'))

      complete!(submitter)

      expect(submitter.reload.completed_at).to be_present
      expect(Quotas.completions_this_month(account)).to eq(1)
      expect(CompletedSubmitter.find_by!(submitter:).is_first).to be(true)
    end

    it 'lets the admin reach the billing page and their own profile' do
      suspend!
      act_as(admin)

      get '/settings/profile'

      expect(response).to have_http_status(:ok)

      expect { put "/users/#{admin.id}", params: { user: { first_name: 'Still' } } }
        .to(change { admin.reload.first_name }.to('Still'))
    end
  end

  # Archived is the OTHER policy, and until Session 7 the signer write paths
  # did not check it at all: the locked page was rendered by `show` while the
  # PUT behind it still went through (Session 2 handoff). Archived means the
  # account is gone, so those writes stop too.
  describe 'an archived account, whose signer writes stop as well' do
    let!(:submission) { send_one }
    let(:submitter) { submission.submitters.first }

    before do
      account.update!(archived_at: Time.current)
      anonymous!
    end

    it 'refuses the signing PUT' do
      put "/s/#{submitter.slug}", params: { completed: 'true', esign_consent: 'true',
                                            esign_consent_version: EsignConsent::VERSION,
                                            values: { text_field(submitter)['uuid'] => 'Jane' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => I18n.t('form_has_been_archived'))
      expect(submitter.reload.completed_at).to be_nil
    end

    it 'refuses a decline' do
      post "/s/#{submitter.slug}/decline", params: { reason: 'No thanks' }

      expect(submitter.reload.declined_at).to be_nil
    end

    it 'refuses a delegation' do
      create(:account_config, account:, key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)

      expect { post "/s/#{submitter.slug}/delegate", params: { email: unique_email } }
        .not_to change(SubmitterVersion, :count)
    end

    it 'refuses an attachment upload' do
      post '/api/attachments', params: {
        submitter_slug: submitter.slug,
        file: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png')
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => I18n.t('form_has_been_archived'))
    end
  end

  describe Ability do
    let(:other_user) { create(:user, account:) }

    it 'takes away every write and leaves every read, plus the user\'s own profile' do
      suspend!
      ability = described_class.new(admin.reload)

      expect(ability.can?(:create, Template.new(account:))).to be(false)
      expect(ability.can?(:update, template)).to be(false)
      expect(ability.can?(:destroy, template)).to be(false)
      expect(ability.can?(:create, Submission.new(account:))).to be(false)
      expect(ability.can?(:update, other_user)).to be(false)
      expect(ability.can?(:manage, :mcp)).to be(false)

      expect(ability.can?(:read, template)).to be(true)
      expect(ability.can?(:read, Submission.new(account:))).to be(true)
      expect(ability.can?(:update, admin)).to be(true)
      # The billing page authorizes this, and it is the one page that can fix
      # the suspension.
      expect(ability.can?(:manage, account)).to be(true)
    end

    it 'leaves an active account\'s abilities exactly as they were' do
      ability = described_class.new(admin)

      expect(ability.can?(:create, Template.new(account:))).to be(true)
      expect(ability.can?(:update, other_user)).to be(true)
    end

    # A linked child is paid for by its parent: when the parent stops paying,
    # the child stops writing too.
    it 'freezes a child account whose parent is suspended' do
      child = create(:account, linked_account_account: AccountLinkedAccount.new(account_type: :linked, account:))
      child_admin = create(:user, account: child)

      expect(described_class.new(child_admin).can?(:create, Template.new(account: child))).to be(true)

      suspend!

      expect(AccountStates.read_only?(child.reload)).to be(true)
      expect(described_class.new(child_admin).can?(:create, Template.new(account: child))).to be(false)
    end
  end
end

# The clock itself: how a failed payment turns into reminders, then a
# suspension, and how paying undoes it. Nothing here calls Stripe — the
# captures go straight into the one mapping every Stripe door shares.
RSpec.describe 'Billing dunning', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:) }
  let(:deliveries) { ActionMailer::Base.deliveries }
  let(:fixture_price) { 'price_1UAt8N4rEeOqtLcX1amJxYdZ' }
  # The five subjects the dunning clock can send, spelled once.
  let(:first_notice) { 'We could not take your EsignCenter payment' }
  let(:reminder) { 'Your EsignCenter payment is still outstanding' }
  let(:last_warning) { 'Last reminder: your EsignCenter account is suspended tomorrow' }
  let(:suspended_subject) { 'Your EsignCenter account is suspended' }
  let(:recovered) { 'Your EsignCenter payment went through' }
  let(:subscription) do
    create(:account_subscription, account:, access_state: 'active', status: 'active',
                                  stripe_customer_id: 'cus_VBqKHh0NHYmvT1',
                                  stripe_subscription_id: 'sub_1UBSds4rEeOqtLcXs81X4tCG')
  end

  stash_env('STRIPE_PRICE_ID')

  before do
    ENV['STRIPE_PRICE_ID'] = fixture_price
    deliveries.clear
  end

  # A real CLI capture, with only `status` changed where a state the CLI
  # cannot easily produce is needed (the same licence stripe_spec takes).
  def apply!(fixture, status: nil)
    body = JSON.parse(Rails.root.join("spec/fixtures/stripe/#{fixture}.json").read)
    body['status'] = status if status

    StripeBilling::SubscriptionSync.apply!(subscription, body)

    subscription.reload
  end

  # Matched on the WHOLE subject: 'Last reminder: … account is suspended
  # tomorrow' and 'Your … account is suspended' share a fragment, and a
  # fragment match would count the warning as the suspension notice.
  def mails_titled(subject)
    deliveries.select { |mail| mail.subject.to_s == subject }
  end

  # The mail is multipart by the time the interceptor is done, so the HTML
  # part is where the words are.
  def body_of(mail)
    (mail.html_part || mail.text_part || mail.body).decoded
  end

  it 'stamps the clock, mails day 0 once, and says nothing on a repeat of the same state', sidekiq: :inline do
    apply!('subscription-past_due')

    expect(subscription.access_state).to eq('past_due')
    expect(subscription.past_due_since).to be_present
    expect(mails_titled(first_notice).size).to eq(1)
    expect(mails_titled(first_notice).sole.to).to eq([admin.email])
    expect(body_of(mails_titled(first_notice).sole))
      .to include((subscription.past_due_since + 14.days).utc.strftime('%-d %B %Y'))

    stamped = subscription.past_due_since

    apply!('subscription-past_due')

    expect(subscription.past_due_since).to eq(stamped)
    expect(mails_titled(first_notice).size).to eq(1)
  end

  it 'mails on days 3, 7 and 13, once each, then suspends on day 14 and mails that', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    [3, 7, 13].each do |day|
      travel_to(started + day.days + 1.hour) do
        2.times { BillingLifecycle.run_dunning! }
      end
    end

    expect(mails_titled(reminder).size).to eq(2)
    expect(mails_titled(last_warning).size).to eq(1)
    expect(account.reload.suspended_at).to be_nil

    travel_to(started + 14.days + 1.hour) do
      2.times { BillingLifecycle.run_dunning! }
    end

    expect(account.reload.suspended_at).to be_present
    expect(account.suspension_reason).to eq('billing')
    expect(mails_titled(suspended_subject).size).to eq(1)
    expect(AccountStates.read_only?(account)).to be(true)
  end

  it 'lifts the suspension and says so once when the payment goes through', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 14.days + 1.hour) { BillingLifecycle.run_dunning! }

    expect(account.reload.suspended_at).to be_present

    apply!('subscription-active-recovered')

    expect(subscription.access_state).to eq('active')
    expect(subscription.past_due_since).to be_nil
    expect(account.reload.suspended_at).to be_nil
    expect(account.suspension_reason).to be_nil
    expect(mails_titled(recovered).size).to eq(1)

    apply!('subscription-active-recovered')

    expect(mails_titled(recovered).size).to eq(1)
  end

  # Stripe says `unpaid` when it gives up on the card. There is no grace left
  # to give at that point, so the account is suspended at once.
  it 'suspends immediately when Stripe gives up on the card', sidekiq: :inline do
    apply!('subscription-past_due', status: 'unpaid')

    expect(subscription.access_state).to eq('suspended')
    expect(account.reload.suspended_at).to be_present
    expect(account.suspension_reason).to eq('billing')
    expect(mails_titled(suspended_subject).size).to eq(1)
  end

  # Review-6 C7: a past_due → unpaid → past_due wobble must not hand the
  # customer a fresh 14 days each time round.
  it 'keeps the original clock through unpaid and back again', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    apply!('subscription-past_due', status: 'unpaid')

    expect(subscription.access_state).to eq('suspended')
    expect(subscription.past_due_since).to eq(started)

    apply!('subscription-past_due')

    expect(subscription.access_state).to eq('past_due')
    expect(subscription.past_due_since).to eq(started)

    # Still inside the 14 days, so the account is back to normal — but the
    # deadline is the original one, not a new one.
    expect(account.reload.suspended_at).to be_nil
    expect(BillingLifecycle.suspends_on(subscription)).to eq(started + 14.days)
  end

  it 'never lets a payment undo an operator suspension', sidekiq: :inline do
    apply!('subscription-past_due')
    started = subscription.past_due_since

    travel_to(started + 14.days + 1.hour) { BillingLifecycle.run_dunning! }

    # The operator takes the decision over: the billing recovery below must
    # not be what lifts it.
    account.reload.update!(suspension_reason: 'operator')

    apply!('subscription-active-recovered')

    expect(account.reload.suspended_at).to be_present
    expect(account.suspension_reason).to eq('operator')
    expect(AccountStates.read_only?(account)).to be(true)
    expect(AccountStates.lift_suspension!(account, reason: 'billing')).to be(false)
  end

  it 'never suspends an internal account through the dunning sweep', sidekiq: :inline do
    internal = create(:account, :internal)
    create(:user, account: internal)
    create(:account_subscription, account: internal, access_state: 'past_due', status: 'past_due',
                                  past_due_since: 30.days.ago)

    BillingLifecycle.run_dunning!

    expect(internal.reload.suspended_at).to be_nil
    expect(deliveries).to be_empty
  end

  it 'names the days that are due and nothing else' do
    row = AccountSubscription.new(past_due_since: nil)

    expect(BillingLifecycle.dunning_step_for(row, now: Time.current)).to eq([])
    expect(BillingLifecycle.suspends_on(row)).to be_nil

    row.past_due_since = Time.current

    expect(BillingLifecycle.dunning_step_for(row, now: Time.current)).to eq([0])
    expect(BillingLifecycle.dunning_step_for(row, now: 8.days.from_now)).to eq([0, 3, 7])
    expect(BillingLifecycle.dunning_step_for(row, now: 20.days.from_now)).to eq([0, 3, 7, 13])
  end
end
