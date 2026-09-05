# frozen_string_literal: true

# The platform-operator console (Session 8, phase B1).
#
# Three claims are pinned here and they are the three that matter:
#
#   1. The surface does not exist for anybody but an enrolled operator. The
#      sweep is written off the ROUTE TABLE, so a page added under /operator
#      next month is covered by this spec the moment it is routed.
#   2. Every number the console prints is the number Quotas would give. The
#      list batches its counts, and a batched count that drifts from the
#      single-account one is a lie an operator would act on.
#   3. Nothing moves without an audit row. Every action's happy path is
#      asserted together with the OperatorEvent it wrote — reason, ip and all
#      — and every refusal is asserted to have changed nothing.
RSpec.describe 'Operator console', type: :request do
  def enroll_two_factor(user)
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)

    user
  end

  # Mirrors how test mode clones an account: the child carries the parent's
  # account_kind, which is exactly why the kind can never be the gate.
  def create_testing_child(parent)
    child = parent.dup.tap { |candidate| candidate.name = "Testing - #{parent.name}" }
    child.uuid = SecureRandom.uuid
    parent.testing_accounts << child
    parent.save!

    child
  end

  let(:operator_account) { create(:account, :operator) }
  let(:operator) { enroll_two_factor(create(:user, :admin, account: operator_account, platform_operator: true)) }
  let(:account) { create(:account, name: 'Northfield Legal') }
  let!(:account_admin) { create(:user, :admin, account:, email: 'jane@northfield.example') }

  def reason_params(extra = {})
    { reason: 'Ticket 4182 — customer asked' }.merge(extra)
  end

  def last_event
    OperatorEvent.newest_first.first
  end

  # A sentence with an apostrophe in it reaches the page HTML-escaped, and a
  # spec that forgets that passes for the wrong reason (or, worse, fails while
  # the page is right).
  def escaped(key, **args)
    ERB::Util.html_escape(I18n.t(key, **args))
  end

  # --- 1. the gate ------------------------------------------------------------

  describe 'the gate' do
    # Every route under /operator, taken from the route table itself rather
    # than a list somebody remembered to update.
    def console_routes(account_id)
      Rails.application.routes.routes.filter_map do |route|
        controller = route.defaults[:controller].to_s

        next unless controller.start_with?('operator/')

        path = route.path.spec.to_s.sub('(.:format)', '').sub(':id', account_id.to_s)

        [route.verb.to_s.downcase.to_sym, path]
      end.uniq
    end

    it 'has at least the accounts, audit-log and placeholder routes to sweep' do
      paths = console_routes(account.id).map(&:last)

      expect(paths).to include('/operator/accounts', "/operator/accounts/#{account.id}", '/operator/events',
                               '/operator/abuse', '/operator/settings')
      expect(console_routes(account.id).size).to be >= 15
    end

    [
      ['an anonymous visitor', -> {}],
      ['a customer admin', -> { account_admin }],
      ['an internal admin', -> { create(:user, :admin, account: create(:account, :internal)) }],
      ['an operator-flagged user without 2FA',
       -> { create(:user, :admin, account: operator_account, platform_operator: true) }],
      ['an admin inside a testing child of the operator account',
       lambda {
         child = create_testing_child(operator_account)

         enroll_two_factor(create(:user, :admin, account: child))
       }],
      # The two halves of `User#operator_access?` that nothing swept before
      # (review 8, proof coverage). Neither is exotic: the first is what any
      # ordinary member of the operations team looks like before they are
      # given the flag, and the second is what an admin can do to somebody
      # else's login without a single OTP ever being entered — flipping
      # `otp_required_for_login` on its own. Enrolled means a SECRET exists.
      ['an enrolled admin of the operator account who was never flagged',
       -> { enroll_two_factor(create(:user, :admin, account: operator_account)) }],
      ['an operator-flagged user with 2FA required but never enrolled',
       lambda {
         create(:user, :admin, account: operator_account, platform_operator: true,
                               otp_required_for_login: true, otp_secret: nil)
       }]
    ].each do |description, build_user|
      it "has no route under /operator for #{description}" do
        operator_account
        user = instance_exec(&build_user)

        sign_in(user) if user

        console_routes(account.id).each do |verb, path|
          expect { public_send(verb, path) }.to raise_error(ActionController::RoutingError),
                                                "#{verb.upcase} #{path} was not a 404"
        end
      end
    end

    it 'serves every route under /operator to an enrolled operator' do
      sign_in(operator)

      console_routes(account.id).each do |verb, path|
        public_send(verb, path)

        # A write with no reason is refused (422) rather than 404: the door is
        # there, it simply will not act without one.
        expect(response.status).to be_in([200, 302, 422]), "#{verb.upcase} #{path} answered #{response.status}"
      end
    end

    # Every row above asks for HTML, and HTML is answered by RAISING — the
    # 404 a missing route would raise. A non-HTML caller cannot be answered
    # that way (`OperatorAccess#require_operator_access!` sends a bare
    # `head :not_found` instead), so it is a second code path, and until now
    # nothing swept it: a JSON or Turbo-stream probe that came back with a
    # rendered error, a redirect, or any body at all would confirm the surface
    # is there and leak its shape. It has to be a bare 404 in every format —
    # including for an API token, the credential most likely to be pointed at
    # it (review 8, proof coverage).
    it 'answers a bare 404 under /operator for a non-HTML request or an API token' do
      operator_account
      token = create(:user, :admin, account:).access_token.token

      console_routes(account.id).each do |verb, path|
        [{ 'ACCEPT' => 'application/json' },
         { 'ACCEPT' => 'application/json', 'x-auth-token' => token }].each do |headers|
          public_send(verb, path, params: reason_params, headers:)

          expect(response).to have_http_status(:not_found),
                              "#{verb.upcase} #{path} as JSON answered #{response.status}"
          expect(response.body).to be_empty,
                                   "#{verb.upcase} #{path} as JSON answered with a body"
        end
      end

      expect(OperatorEvent.count).to eq(0)
      expect(account.reload.suspended_at).to be_nil
    end

    # Turbo streams take the raising branch rather than the bare-404 one:
    # Rails counts any mime type whose name contains "html" as HTML, and
    # `text/vnd.turbo-stream.html` does. Worth pinning, because it is the
    # format the console's own buttons would use if any of them ever became a
    # stream — and the answer has to be the same missing route either way.
    it 'answers a Turbo-stream probe the same way it answers a browser' do
      operator_account

      console_routes(account.id).each do |verb, path|
        expect { public_send(verb, path, params: reason_params, as: :turbo_stream) }
          .to raise_error(ActionController::RoutingError), "#{verb.upcase} #{path} was not a 404"
      end

      expect(OperatorEvent.count).to eq(0)
    end

    it 'writes nothing when a customer admin tries every write door' do
      operator_account
      sign_in(account_admin)

      console_routes(account.id).each do |verb, path|
        next if verb == :get

        expect { public_send(verb, path, params: reason_params) }.to raise_error(ActionController::RoutingError)
      end

      expect(OperatorEvent.count).to eq(0)
      expect(account.reload.suspended_at).to be_nil
      expect(AccountLimitOverride.count).to eq(0)
    end
  end

  # --- 2. the list ------------------------------------------------------------

  describe 'GET /operator/accounts' do
    before { sign_in(operator) }

    it 'lists customer, internal and operator accounts and never a testing child' do
      internal = create(:account, :internal, name: 'Processor Team')
      child = create_testing_child(account)

      get operator_accounts_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-operator-account-row=\"#{account.id}\"")
      expect(response.body).to include("data-operator-account-row=\"#{internal.id}\"")
      expect(response.body).to include("data-operator-account-row=\"#{operator_account.id}\"")
      expect(response.body).not_to include("data-operator-account-row=\"#{child.id}\"")
      expect(response.body).not_to include('translation missing')
    end

    it 'searches by account id, by name and by any user email' do
      other = create(:account, name: 'Southgate Partners')
      create(:user, :admin, account: other, email: 'ravi@southgate.example')

      get operator_accounts_path(q: account.id.to_s)
      expect(response.body).to include("data-operator-account-row=\"#{account.id}\"")
      expect(response.body).not_to include("data-operator-account-row=\"#{other.id}\"")

      get operator_accounts_path(q: 'Southgate')
      expect(response.body).to include("data-operator-account-row=\"#{other.id}\"")
      expect(response.body).not_to include("data-operator-account-row=\"#{account.id}\"")

      get operator_accounts_path(q: 'ravi@southgate')
      expect(response.body).to include("data-operator-account-row=\"#{other.id}\"")
      expect(response.body).not_to include("data-operator-account-row=\"#{account.id}\"")

      get operator_accounts_path(q: 'nobody-at-all')
      expect(response.body).to include('data-operator-no-accounts')
    end

    it 'filters by kind, by plan and by every state chip' do
      internal = create(:account, :internal)
      paid = create(:account, :paid, name: 'Paid Co')
      comped = create(:account, name: 'Comped Co')
      Plans::Manual.grant!(comped, seats: 2, comp_expires_at: 10.days.from_now)
      suspended = create(:account, name: 'Frozen Co')
      AccountStates.suspend!(suspended, reason: 'operator')
      paused = create(:account, name: 'Paused Co')
      paused.update!(sending_paused_at: Time.current, sending_pause_reason: 'complaint')
      leaving = create(:account, name: 'Leaving Co')
      leaving.update!(deletion_requested_at: Time.current, purge_scheduled_for: 90.days.from_now)
      archived = create(:account, name: 'Gone Co')
      archived.update!(archived_at: Time.current)
      purged = create(:account, name: 'Deleted account')
      purged.update!(purged_at: Time.current)
      parked = create(:user, account:, role: User::EDITOR_ROLE, read_only_at: Time.current)

      expect(parked).to be_read_only

      { { kind: Account::INTERNAL_KIND } => internal,
        { plan: 'active' } => paid,
        { plan: 'comp' } => comped,
        { plan: 'free' } => account,
        { state: 'suspended' } => suspended,
        { state: 'sending_paused' } => paused,
        { state: 'pending_deletion' } => leaving,
        { state: 'archived' } => archived,
        { state: 'purged' } => purged,
        { state: 'read_only_members' } => account }.each do |filter, expected|
        get operator_accounts_path(**filter)

        expect(response).to have_http_status(:ok), filter.inspect
        expect(response.body).to include("data-operator-account-row=\"#{expected.id}\""), filter.inspect
      end

      get operator_accounts_path(kind: Account::INTERNAL_KIND)
      expect(response.body).not_to include("data-operator-account-row=\"#{account.id}\"")

      get operator_accounts_path(plan: 'active')
      expect(response.body).not_to include("data-operator-account-row=\"#{account.id}\"")
    end

    it 'finds the accounts whose storage is over their cap' do
      create(:template, account:)
      AccountLimitOverride.create!(account:, storage_bytes: 1)

      get operator_accounts_path(state: 'storage_over_cap')

      expect(response.body).to include("data-operator-account-row=\"#{account.id}\"")
      expect(response.body).to include('data-state-badge="storage_over_cap"')

      other = create(:account)
      create(:user, :admin, account: other)

      expect(response.body).not_to include("data-operator-account-row=\"#{other.id}\"")
    end

    it 'sorts by id, name and last activity' do
      later = create(:account, name: 'Aardvark Ltd', last_active_at: Time.current)
      account.update!(last_active_at: 3.days.ago)

      get operator_accounts_path(sort: 'id')
      expect(response.body.index("data-operator-account-row=\"#{account.id}\""))
        .to be < response.body.index("data-operator-account-row=\"#{later.id}\"")

      get operator_accounts_path(sort: 'name')
      expect(response.body.index("data-operator-account-row=\"#{later.id}\""))
        .to be < response.body.index("data-operator-account-row=\"#{account.id}\"")

      get operator_accounts_path(sort: 'last_active')
      expect(response.body.index("data-operator-account-row=\"#{later.id}\""))
        .to be < response.body.index("data-operator-account-row=\"#{account.id}\"")
    end
  end

  # --- 3. the batched numbers -------------------------------------------------

  describe 'OperatorConsole batching' do
    # A batched count that drifts from Quotas is a number an operator would
    # act on, so every one of them is pinned against the single-account
    # function it replaces — on a family, so the roll-up is exercised too.
    it 'gives exactly the numbers Quotas gives, account by account' do
      paid = create(:account, :paid, seats: 3)
      create(:user, :admin, account: paid)
      child = create(:account, name: 'Team A',
                               linked_account_account: AccountLinkedAccount.new(account_type: :linked,
                                                                                account: paid))
      create(:user, :admin, account: child)
      template = create(:template, account: paid)
      submission = create(:submission, :with_submitters, template:, account: paid)
      create(:template, account: child)

      CompletedSubmitter.create!(account: paid, submission:, submitter: submission.submitters.first,
                                 template:, completed_at: Time.current, is_first: true,
                                 sms_count: 0, source: 'invite')
      AccountCounters.increment!(paid.id, 'submissions_created', by: 4)
      AccountCounters.increment!(child.id, 'submissions_created', by: 2)

      accounts = [account, paid, child]
      usage = OperatorConsole.usage_for(accounts)

      accounts.each do |candidate|
        billing = Plans.billing_account(candidate)
        row = usage.fetch(candidate.id)

        expect(row.completions).to eq(Quotas.completions_this_month(billing)), candidate.name
        expect(row.sends).to eq(Quotas.sends_this_month(billing)), candidate.name
        expect(row.in_flight).to eq(Quotas.in_flight(billing)), candidate.name
        expect(row.storage_bytes).to eq(Quotas::Storage.bytes_used(billing)), candidate.name
        expect(row.seats_used).to eq(Accounts.users_count(billing)), candidate.name
        expect(row.limits.to_h).to eq(Quotas.limits_for(billing).to_h), candidate.name
      end

      # Six seeded, plus the one the submission above created through the
      # real counter — the point is that the batched number and Quotas agree.
      expect(usage.fetch(paid.id).sends).to eq(7)
      expect(usage.fetch(paid.id).storage_bytes).to be_positive
    end

    # D43: a downgrade part-way through the month makes the free month start
    # at the downgrade, and the batched query has to measure the same window.
    it 'measures the prospective free month a downgrade starts' do
      travel_to(Time.current.utc.beginning_of_month + 2.days) do
        paid = create(:account, :paid)
        create(:user, :admin, account: paid)

        AccountCounters.increment!(paid.id, 'submissions_created', by: 7)
        downgrade_to_free!(paid)
        AccountCounters.increment!(paid.id, 'submissions_created', by: 2)

        expect(OperatorConsole.usage_for([paid]).fetch(paid.id).sends).to eq(Quotas.sends_this_month(paid))
        expect(Quotas.sends_this_month(paid)).to eq(2)
      end
    end

    it 'weighs storage the same way Quotas::Storage does, for every record type it counts' do
      template = create(:template, account:)
      submission = create(:submission, :with_submitters, template:, account:)

      account.logo.attach(io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
                          filename: 'logo.pdf', content_type: 'application/pdf')
      account_admin.signature.attach(io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
                                     filename: 'signature.pdf', content_type: 'application/pdf')
      submission.submitters.first.attachments.attach(
        io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
        filename: 'field.pdf', content_type: 'application/pdf'
      )
      submission.documents.attach(io: Rails.root.join('spec/fixtures/sample-document.pdf').open,
                                  filename: 'signed.pdf', content_type: 'application/pdf')

      expect(OperatorConsole.bytes_by_account([account.id]).fetch(account.id))
        .to eq(Quotas::Storage.bytes_used(account))
      expect(Quotas::Storage.bytes_used(account)).to be_positive
    end
  end

  # --- 4. one account ---------------------------------------------------------

  describe 'GET /operator/accounts/:id' do
    before { sign_in(operator) }

    it 'renders every section for a free account' do
      create(:template, account:)
      create(:account_invite, account:)
      AbuseFlags.record!(account, 'fair_use_review', period: '2026-09', details: { completions: 12 })
      ProvisioningEvent.create!(account:, email: account_admin.email, idempotency_key: 'prov-1')

      get operator_account_path(account)

      expect(response).to have_http_status(:ok)
      %w[data-operator-actions data-operator-billing data-operator-limits data-operator-users
         data-operator-invites data-operator-abuse data-operator-deletion data-operator-provisioning
         data-operator-history].each do |marker|
        expect(response.body).to include(marker), marker
      end
      expect(response.body).to include('data-plan-badge="free"')
      expect(response.body).to include('data-no-subscription')
      expect(response.body).not_to include('translation missing')
    end

    it 'renders a paid, Stripe-backed account with its ids and no key' do
      paid = create(:account, :paid, seats: 4)
      create(:user, :admin, account: paid)
      paid.account_subscription.update!(status: 'active', stripe_status: 'active',
                                        stripe_subscription_id: 'sub_live', stripe_customer_id: 'cus_live',
                                        current_period_start: 2.days.ago, current_period_end: 28.days.from_now)

      get operator_account_path(paid)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-plan-badge="paid"')
      expect(response.body).to include('sub_live').and include('cus_live')
      expect(response.body).not_to include('sk_test')
      expect(response.body).not_to include('sk_live')
    end

    it 'says an internal account has no caps and offers it no forms' do
      internal = create(:account, :internal)
      create(:user, :admin, account: internal)

      get operator_account_path(internal)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-limits-internal')
      expect(response.body).to include('data-operator-actions-refused')
      expect(response.body).not_to include('data-operator-action="suspend"')
      expect(response.body).not_to include('data-operator-action="comp_grant"')
    end

    it 'shows a suspended account its reason and only the doors that could work' do
      AccountStates.suspend!(account, reason: 'operator')

      get operator_account_path(account)

      expect(response.body).to include('data-state-badge="suspended"')
      expect(response.body).to include('data-operator-action="lift_suspension"')
      expect(response.body).not_to include('data-operator-action="suspend"')
    end

    it 'refuses to lift a billing suspension from here and says why on the page' do
      AccountStates.suspend!(account, reason: BillingLifecycle::SUSPENSION_REASON)

      get operator_account_path(account)

      expect(response.body).to include('data-suspension-not-liftable')
      expect(response.body).to include(I18n.t('operator_refused_suspension_billing'))
      expect(response.body).not_to include('data-operator-action="lift_suspension"')
    end

    it 'labels the legacy API-only login and explains what replaces it' do
      create(:user, account:, role: 'integration', email: 'api@northfield.example')

      get operator_account_path(account)

      expect(response.body).to include('data-integration-role')
      expect(response.body).to include('API integration (legacy)')
      expect(response.body).to include(I18n.t('integration_role_tooltip'))
      expect(response.body).to include(escaped('integration_users_help'))
    end

    it 'lists invitations in every state, read-only' do
      pending_invite = create(:account_invite, account:, email: 'pending@example.com')
      create(:account_invite, account:, email: 'parked@example.com',
                              payment_pending_until: 1.day.from_now, pending_quantity: 2)

      get operator_account_path(account)

      expect(response.body).to include("data-operator-invite-row=\"#{pending_invite.id}\"")
      expect(response.body).to include('data-invite-state="pending"')
      expect(response.body).to include('data-invite-state="payment_pending"')
    end

    it 'is a 404 for a testing child, which is a corner of its parent rather than an account' do
      child = create_testing_child(account)

      expect { get operator_account_path(child) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # --- 5. state actions -------------------------------------------------------

  describe 'state actions' do
    before { sign_in(operator) }

    it 'suspends an account and records who, why and from where' do
      post suspend_operator_account_path(account), params: reason_params

      expect(response).to redirect_to(operator_account_path(account))
      expect(account.reload.suspended_at).to be_present
      expect(account.suspension_reason).to eq('operator')
      expect(last_event).to have_attributes(action: 'account.suspend', account_id: account.id,
                                            operator_user_id: operator.id,
                                            reason: 'Ticket 4182 — customer asked')
      expect(last_event.ip).to be_present
    end

    it 'lifts only its own suspension' do
      AccountStates.suspend!(account, reason: 'operator')

      post lift_suspension_operator_account_path(account), params: reason_params

      expect(account.reload.suspended_at).to be_nil
      expect(last_event.action).to eq('account.lift_suspension')
    end

    it 'refuses to lift a billing suspension, changes nothing and stays on the page' do
      AccountStates.suspend!(account, reason: BillingLifecycle::SUSPENSION_REASON)

      post lift_suspension_operator_account_path(account), params: reason_params

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('operator_refused_suspension_billing'))
      expect(account.reload.suspended_at).to be_present
      expect(OperatorEvent.count).to eq(0)
    end

    it 'resumes sending and resolves the flags the pause raised' do
      SendingPause.pause!(account, reason: 'complaint', details: { email: 'x@example.com' })

      expect(account.reload.sending_paused_at).to be_present

      post resume_sending_operator_account_path(account), params: reason_params

      expect(account.reload.sending_paused_at).to be_nil
      expect(account.abuse_flags.open.where(kind: SendingPause::FLAG_KINDS)).to be_empty
      expect(last_event.action).to eq('sending.resume')
    end

    # A1 (review 8). The Resume button lifted the pause and the account was
    # back inside the minute: the bounce window it is judged by still held the
    # very bounces that caused it, so the next one re-paused immediately. The
    # button now moves the watermark, which is what makes it a real resume.
    it 'really lifts a bounce-rate pause: the bounces it was paused for cannot re-pause it' do
      stub_const('Quotas::Limits::BOUNCE_MIN_SENDS', 4)
      stub_const('Quotas::Limits::BOUNCE_PAUSE_RATE', 0.5)

      owner = create(:user, :admin, account:)
      template = create(:template, account:, author: owner)
      submitter = create(:submission, :with_submitters, template:, created_by_user: owner).submitters.first
      sends = Array.new(4) do
        create(:email_event, account:, emailable: submitter, event_type: 'send', email: submitter.email)
      end
      bounce = nil
      sends.first(2).each do |sent|
        bounce = create(:email_event, account:, emailable: submitter, event_type: 'permanent_bounce',
                                      message_id: sent.message_id, email: sent.email)
      end

      SendingPause.evaluate!(account, event: bounce)

      expect(account.reload.sending_paused_at).to be_present

      post resume_sending_operator_account_path(account), params: reason_params

      expect(account.reload.sending_paused_at).to be_nil
      expect(SendingPause.bounce_rate(account)).to be_nil

      # The same evidence, presented again, changes nothing.
      SendingPause.evaluate!(account, event: bounce)

      expect(account.reload.sending_paused_at).to be_nil
    end

    it 'refuses to resume sending that was never paused' do
      post resume_sending_operator_account_path(account), params: reason_params

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('operator_refused_not_paused'))
      expect(OperatorEvent.count).to eq(0)
    end

    it 'cancels a scheduled deletion and unfreezes the account' do
      Accounts::Deletion.request!(account, requested_by: account_admin)

      expect(account.reload).to be_pending_deletion

      post cancel_deletion_operator_account_path(account), params: reason_params

      expect(account.reload.pending_deletion?).to be(false)
      expect(account.suspended_at).to be_nil
      expect(last_event).to have_attributes(action: 'deletion.cancel', account_id: account.id)
    end

    it 'refuses to cancel a deletion nobody asked for' do
      post cancel_deletion_operator_account_path(account), params: reason_params

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('operator_refused_not_pending_deletion'))
      expect(OperatorEvent.count).to eq(0)
    end

    it 'refuses to cancel a deletion a purge has already claimed' do
      Accounts::Deletion.request!(account, requested_by: account_admin)
      Accounts::Purge.claim!(account.reload)

      post cancel_deletion_operator_account_path(account.reload), params: reason_params

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('operator_refused_purge_claimed'))
      expect(account.reload).to be_pending_deletion
      expect(OperatorEvent.count).to eq(0)
    end

    describe 'purge now' do
      def queued_purges
        Sidekiq::Queues.jobs_by_queue.values.flatten.count { |job| job.to_json.include?('AccountPurgeJob') }
      end

      before do
        account.update!(deletion_requested_at: 91.days.ago, purge_scheduled_for: 1.day.ago)
      end

      it 'queues the purge once the operator types the account name back' do
        post purge_operator_account_path(account), params: reason_params(confirm_name: account.name)

        expect(response).to redirect_to(operator_account_path(account))
        queued = Sidekiq::Queues.jobs_by_queue.values.flatten.select { |job| job.to_json.include?('AccountPurgeJob') }
        expect(queued.size).to eq(1)
        expect(last_event.action).to eq('purge.run')
      end

      # A2 (review 8). The audit row and the enqueue used to be in one
      # transaction with Sidekiq outside it, so a COMMIT that failed after the
      # enqueue left the one irreversible action in the queue with no record of
      # who asked for it. The job now enqueues only when the decision commits,
      # declared on the job so every door that starts a purge inherits it.
      it 'enqueues nothing when the transaction that decided the purge rolls back' do
        expect do
          ApplicationRecord.transaction do
            AccountPurgeJob.perform_later(account.id)

            raise ActiveRecord::Rollback
          end
        end.not_to(change { queued_purges })

        expect do
          ApplicationRecord.transaction { AccountPurgeJob.perform_later(account.id) }
        end.to(change { queued_purges }.by(1))
      end

      it 'refuses a name that does not match and queues nothing' do
        post purge_operator_account_path(account), params: reason_params(confirm_name: 'Northfield')

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_purge_name'))
        expect(Sidekiq::Queues.jobs_by_queue.values.flatten.to_json).not_to include('AccountPurgeJob')
        expect(OperatorEvent.count).to eq(0)
      end

      it 'refuses an account that is not due to be purged: the console has no FORCE' do
        account.update!(deletion_requested_at: nil, purge_scheduled_for: nil)

        post purge_operator_account_path(account), params: reason_params(confirm_name: account.name)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('operator_refused_purge_not_due'))
        expect(Sidekiq::Queues.jobs_by_queue.values.flatten.to_json).not_to include('AccountPurgeJob')
      end

      it 'refuses an account that still holds a live paid subscription' do
        create(:account_subscription, account:, access_state: 'active', status: 'active', stripe_status: 'active',
                                      stripe_subscription_id: 'sub_live')

        post purge_operator_account_path(account), params: reason_params(confirm_name: account.name)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('live paid subscription')
        expect(OperatorEvent.count).to eq(0)
      end

      it 'refuses an account a purge has already claimed' do
        Accounts::Purge.claim!(account)

        post purge_operator_account_path(account.reload), params: reason_params(confirm_name: account.name)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('operator_refused_purge_claimed'))
      end
    end

    describe 'release a stuck purge claim' do
      it 'releases a claim older than an hour and puts the account back' do
        Accounts::Purge.claim!(account)
        account.update_columns(purge_started_at: 3.hours.ago)

        get operator_account_path(account)
        expect(response.body).to include('data-operator-action="release_purge_claim"')

        post release_purge_claim_operator_account_path(account), params: reason_params

        expect(account.reload.purge_started_at).to be_nil
        expect(account.archived_at).to be_nil
        expect(last_event.action).to eq('purge.release_claim')
      end

      it 'is neither offered nor allowed while the claim is fresh' do
        Accounts::Purge.claim!(account)

        get operator_account_path(account)
        expect(response.body).not_to include('data-operator-action="release_purge_claim"')

        post release_purge_claim_operator_account_path(account), params: reason_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('operator_refused_claim_not_stale'))
        expect(account.reload.purge_started_at).to be_present
      end
    end

    it 'shows the orphan check without writing anything' do
      get orphans_operator_account_path(account)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-operator-orphans')
      expect(response.body).to include('data-orphan-count="submitters"')
      expect(OperatorEvent.count).to eq(0)
    end

    it 'refuses every action without a reason, and changes nothing' do
      { suspend_operator_account_path(account) => :post,
        purge_operator_account_path(account) => :post,
        comp_revoke_operator_account_path(account) => :post,
        limits_operator_account_path(account) => :patch }.each do |path, verb|
        public_send(verb, path, params: { reason: 'no' })

        expect(response).to have_http_status(:unprocessable_content), path
        expect(response.body).to include(I18n.t('operator_refused_reason_required',
                                                count: Operator::BaseController::MINIMUM_REASON_LENGTH))
      end

      expect(account.reload.suspended_at).to be_nil
      expect(OperatorEvent.count).to eq(0)
      expect(AccountLimitOverride.count).to eq(0)
    end

    it 'refuses every action on an internal account and on the operator account itself' do
      internal = create(:account, :internal)
      create(:user, :admin, account: internal)

      [internal, operator_account].each do |platform|
        post suspend_operator_account_path(platform), params: reason_params

        expect(response).to have_http_status(:unprocessable_content), platform.account_kind
        expect(response.body).to include(I18n.t('operator_refused_platform_account',
                                                kind: platform.account_kind))
        expect(platform.reload.suspended_at).to be_nil
      end

      expect(OperatorEvent.count).to eq(0)
    end
  end

  # --- 6. limits --------------------------------------------------------------

  describe 'PATCH /operator/accounts/:id/limits' do
    before { sign_in(operator) }

    it 'upserts the override and Quotas reads it back' do
      patch limits_operator_account_path(account),
            params: reason_params(limits: { completions_per_month: '50', sends_per_month: '',
                                            in_flight: '', seats: '4', storage_gb: '25',
                                            fair_use_per_seat: '900', sends_per_day_per_seat: '',
                                            in_flight_per_seat: '' })

      expect(response).to redirect_to(operator_account_path(account))

      limits = Quotas.limits_for(account.reload)

      expect(limits.completions_per_month).to eq(50)
      expect(limits.seats).to eq(4)
      expect(limits.storage_bytes).to eq(25 * 1.gigabyte)
      expect(limits.sends_per_month).to eq(Quotas::Limits::FREE_SENDS_PER_MONTH)
      expect(account.limit_override.fair_use_per_seat).to eq(900)
      expect(last_event).to have_attributes(action: 'limits.update', account_id: account.id)
      expect(last_event.details['after']['completions_per_month']).to eq(50)
    end

    it 'clears an override back to the plan default when the field is blanked' do
      AccountLimitOverride.create!(account:, completions_per_month: 99)

      patch limits_operator_account_path(account),
            params: reason_params(limits: { completions_per_month: '' })

      expect(Quotas.limits_for(account.reload).completions_per_month)
        .to eq(Quotas::Limits::FREE_COMPLETIONS_PER_MONTH)
      expect(last_event.details['before']['completions_per_month']).to eq(99)
    end

    # Review 1, M1: Quotas.limits_for resolves the BILLING account before it
    # reads an override, so a row saved on a linked child was read by nothing
    # — the page painted the "Override" badge over a cap that had not moved.
    it 'writes a linked child\'s override on the account that pays for it, and says so' do
      parent = create(:account, name: 'Parent Group')
      create(:user, :admin, account: parent)
      child = create(:account, name: 'Team A',
                               linked_account_account: AccountLinkedAccount.new(account_type: :linked,
                                                                                account: parent))
      create(:user, :admin, account: child)

      patch limits_operator_account_path(child),
            params: reason_params(limits: { completions_per_month: '99' })

      expect(response).to redirect_to(operator_account_path(child))
      expect(parent.reload.limit_override&.completions_per_month).to eq(99)
      expect(child.reload.limit_override).to be_nil
      expect(Quotas.limits_for(child).completions_per_month).to eq(99)
      expect(last_event.details['billing_account_id']).to eq(parent.id)

      get operator_account_path(child)

      expect(response.body).to include('data-limits-billing-account')
      expect(response.body).to include('data-limit-overridden="completions_per_month"')
    end

    it 'refuses an internal account, which has no caps to override' do
      internal = create(:account, :internal)
      create(:user, :admin, account: internal)

      patch limits_operator_account_path(internal), params: reason_params(limits: { seats: '9' })

      expect(response).to have_http_status(:unprocessable_content)
      expect(AccountLimitOverride.count).to eq(0)
      expect(OperatorEvent.count).to eq(0)
    end

    it 'refuses a negative number without a 500' do
      patch limits_operator_account_path(account), params: reason_params(limits: { seats: '-3' })

      expect(response).to have_http_status(:unprocessable_content)
      expect(AccountLimitOverride.count).to eq(0)
    end

    # B-L4 (review 1). `"ten".to_i` is 0, and 0 is a real cap here — "this
    # account may not complete a single document this month". A typo used to
    # save cleanly as the harshest limit in the form, with an audit row saying
    # the operator had chosen it.
    it 'refuses a limit that is not a number instead of reading it as zero' do
      { { completions_per_month: 'ten' } => ['completions per month', 'ten'],
        { seats: '4 seats' } => ['seats', '4 seats'],
        { storage_gb: 'lots' } => ['storage (GB)', 'lots'],
        { fair_use_per_seat: '1e3' } => ['fair use per seat', '1e3'] }.each do |limits, (field, value)|
        patch limits_operator_account_path(account), params: reason_params(limits:)

        expect(response).to have_http_status(:unprocessable_content), limits.inspect
        expect(response.body).to include(escaped('operator_refused_limit_not_a_number', field:, value:))
        expect(AccountLimitOverride.count).to eq(0)
        expect(OperatorEvent.count).to eq(0)
      end
    end

    # And the decimal the storage field is actually typed in still works.
    it 'accepts a fractional number of gigabytes' do
      patch limits_operator_account_path(account), params: reason_params(limits: { storage_gb: '1.5' })

      expect(response).to redirect_to(operator_account_path(account))
      expect(Quotas.limits_for(account.reload).storage_bytes).to eq((1.5 * 1.gigabyte).round)
    end
  end

  # --- 7. comp ----------------------------------------------------------------

  describe 'comp' do
    before { sign_in(operator) }

    it 'grants paid access with an expiry and gating follows' do
      expect(Plans.paid_or_better?(account)).to be(false)

      post comp_grant_operator_account_path(account),
           params: reason_params(seats: '3', comp_expires_on: 14.days.from_now.utc.to_date.to_s)

      expect(response).to redirect_to(operator_account_path(account))

      account.reload

      expect(Plans.paid_or_better?(account)).to be(true)
      expect(Entitlements.allowed?(account, :api)).to be(true)
      expect(account.account_subscription).to have_attributes(access_state: 'active', status: 'manual', quantity: 3)
      expect(account.account_subscription.comp_expires_at).to be_present
      expect(last_event.action).to eq('comp.grant')
      expect(last_event.details['seats']).to eq(3)
    end

    it 'refuses a grant with no expiry: comps always expire' do
      post comp_grant_operator_account_path(account), params: reason_params(seats: '2', comp_expires_on: '')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('operator_refused_comp_expiry_required'))
      expect(account.reload.account_subscription).to be_nil
    end

    it 'refuses an expiry in the past' do
      post comp_grant_operator_account_path(account),
           params: reason_params(comp_expires_on: 2.days.ago.utc.to_date.to_s)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('operator_refused_comp_expiry_past'))
      expect(account.reload.account_subscription).to be_nil
    end

    it 'refuses a row Stripe is driving' do
      row = create(:account_subscription, account:, access_state: 'active', status: 'active',
                                          stripe_status: 'active', stripe_subscription_id: 'sub_live')

      post comp_grant_operator_account_path(account),
           params: reason_params(comp_expires_on: 7.days.from_now.utc.to_date.to_s)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('cancel it at Stripe')
      expect(row.reload.status).to eq('active')
      expect(row.comp_expires_at).to be_nil
      expect(OperatorEvent.count).to eq(0)
    end

    # Review carry-over C9: the grant used to land and the next webhook wrote
    # straight over it, so the operator's comp vanished with nobody told.
    it 'refuses while a Stripe checkout is in flight' do
      row = create(:account_subscription, account:, access_state: 'cancelled', status: 'none',
                                          stripe_customer_id: 'cus_checkout')

      post comp_grant_operator_account_path(account),
           params: reason_params(comp_expires_on: 7.days.from_now.utc.to_date.to_s)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('checkout in progress')
      expect(row.reload.access_state).to eq('cancelled')
      expect(Plans.paid_or_better?(account.reload)).to be(false)

      post comp_revoke_operator_account_path(account), params: reason_params

      expect(response).to have_http_status(:unprocessable_content)
      expect(OperatorEvent.count).to eq(0)
    end

    it 'revokes a comp and starts the free month at the revoke (D43)' do
      Plans::Manual.grant!(account, seats: 2, comp_expires_at: 10.days.from_now)
      AccountCounters.increment!(account.id, 'submissions_created', by: 6)

      post comp_revoke_operator_account_path(account), params: reason_params

      account.reload

      expect(Plans.key_for(account)).to eq(Plans::FREE)
      expect(account.account_subscription.comp_expires_at).to be_nil
      expect(account.account_subscription.ended_at).to be_present
      expect(Quotas.sends_this_month(account)).to eq(0)
      expect(AccountCounters.value(account.id, 'submissions_created')).to eq(6)
      expect(last_event.action).to eq('comp.revoke')
    end

    # Review 1 (Codex): a paid plan ending by hand ends it exactly as Stripe
    # ending it does — counters AND seats. Before this, revoking a comp that
    # three people were sitting on left all three writing indefinitely: the
    # hourly seat sweep only ever looks at Stripe-backed rows, so nothing else
    # would ever have noticed.
    it 'parks the surplus seats and hands back held invitations when a comp is revoked' do
      Plans::Manual.grant!(account, seats: 3, comp_expires_at: 10.days.from_now)
      second = create(:user, :admin, account:, email: "second-#{SecureRandom.hex(4)}@northfield.example")
      third = create(:user, account:, role: User::EDITOR_ROLE, email: "third-#{SecureRandom.hex(4)}@northfield.example")
      invite = create(:account_invite, account:, email: "fourth-#{SecureRandom.hex(4)}@northfield.example")

      expect(Accounts.seat_occupancy(account)).to eq(4)

      post comp_revoke_operator_account_path(account), params: reason_params

      expect(response).to redirect_to(operator_account_path(account))
      expect(Plans.key_for(account.reload)).to eq(Plans::FREE)

      kept = [account_admin, second, third].map { |user| user.reload.read_only_at.nil? }

      expect(kept.count(true)).to eq(1)
      expect([account_admin, second].filter_map { |user| user.reload.read_only_at }.size).to eq(1)
      expect(third.reload.read_only_at).to be_present
      expect(invite.reload.revoked_at).to be_present
      expect(Accounts.seat_occupancy(account)).to eq(1)
    end

    it 'parks the surplus seats the same way when the comp expires on the clock' do
      Plans::Manual.grant!(account, seats: 3, comp_expires_at: 2.days.from_now)
      create(:user, :admin, account:, email: "second-#{SecureRandom.hex(4)}@northfield.example")
      third = create(:user, account:, role: User::EDITOR_ROLE, email: "third-#{SecureRandom.hex(4)}@northfield.example")
      invite = create(:account_invite, account:, email: "fourth-#{SecureRandom.hex(4)}@northfield.example")

      travel_to(3.days.from_now) do
        CompExpiryJob.new.perform

        expect(Plans.key_for(account.reload)).to eq(Plans::FREE)
        expect(third.reload.read_only_at).to be_present
        expect(invite.reload.revoked_at).to be_present
        expect(Accounts.seat_occupancy(account)).to eq(1)
      end
    end

    # `rake plans:revoke` is the same door onto the same code, so it inherits
    # the seat transition rather than needing one of its own.
    it 'parks the surplus seats when the plan is revoked from the rake task path' do
      Plans::Manual.grant!(account, seats: 3, comp_expires_at: 10.days.from_now)
      create(:user, :admin, account:, email: "second-#{SecureRandom.hex(4)}@northfield.example")
      third = create(:user, account:, role: User::EDITOR_ROLE, email: "third-#{SecureRandom.hex(4)}@northfield.example")

      Plans::Manual.revoke!(account)

      expect(Plans.key_for(account.reload)).to eq(Plans::FREE)
      expect(third.reload.read_only_at).to be_present
      expect(Accounts.seat_occupancy(account)).to eq(1)
    end

    # Review 1 (Codex): manual writes now take the SAME row lock every Stripe
    # writer takes and re-decide inside it. The wrap below stands in for the
    # webhook that lands in the window the lock closes — before the fix there
    # was no lock to land inside, the stale object still read `manual`, and
    # the revoke wiped a `stripe_subscription_id` that had just arrived,
    # leaving a subscription charging the customer with nothing watching it.
    it 'refuses a revoke when a Stripe subscription arrives while the row is being locked' do
      Plans::Manual.grant!(account, seats: 1, comp_expires_at: 10.days.from_now)
      row = account.reload.account_subscription

      allow(StripeBilling::Linker).to receive(:with_account_lock).and_wrap_original do |original, subscription, &block|
        AccountSubscription.where(id: subscription.id)
                           .update_all(status: 'active', stripe_status: 'active',
                                       stripe_subscription_id: 'sub_arrived_late')

        original.call(subscription, &block)
      end

      post comp_revoke_operator_account_path(account), params: reason_params

      # The refusal rolls the whole transaction back — the stand-in webhook
      # write with it — so what is asserted is the thing that matters: the
      # manual path did NOT downgrade the account or clear a Stripe id out
      # from under a live subscription, and it wrote no audit line.
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('cancel it at Stripe')
      expect(Plans.key_for(account.reload)).to eq(Plans::PAID)
      expect(row.reload.status).to eq('manual')
      expect(OperatorEvent.count).to eq(0)
    end

    it 'refuses a revoke when there is no subscription row at all' do
      post comp_revoke_operator_account_path(account), params: reason_params

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('operator_refused_no_subscription'))
    end

    describe 'CompExpiryJob' do
      it 'revokes a comp whose date has passed and records it as the system' do
        Plans::Manual.grant!(account, seats: 2, comp_expires_at: 2.days.from_now)

        expect(Plans.paid_or_better?(account.reload)).to be(true)

        travel_to(3.days.from_now) do
          CompExpiryJob.new.perform

          account.reload

          expect(Plans.key_for(account)).to eq(Plans::FREE)
          expect(account.account_subscription.comp_expires_at).to be_nil
          expect(last_event).to have_attributes(action: 'comp.expire', account_id: account.id,
                                                operator_user_id: nil)
          expect(last_event.operator_label).to eq(I18n.t('operator_event_system_actor'))
        end
      end

      # The sweep chose this row minutes ago. An operator extending the comp in
      # between must not have it taken away by a job that is already running:
      # the date is re-read under the row lock, and a row that no longer
      # answers "expired" is left alone — audit line included.
      it 'does not expire a comp the operator extended after the sweep had selected it' do
        Plans::Manual.grant!(account, seats: 1, comp_expires_at: 2.days.from_now)

        travel_to(3.days.from_now) do
          allow(StripeBilling::Linker).to receive(:with_account_lock)
            .and_wrap_original do |original, subscription, &block|
              AccountSubscription.where(id: subscription.id).update_all(comp_expires_at: 30.days.from_now)

              original.call(subscription, &block)
            end

          CompExpiryJob.new.perform

          expect(Plans.paid_or_better?(account.reload)).to be(true)
          expect(account.account_subscription.comp_expires_at).to be > Time.current
          expect(OperatorEvent.count).to eq(0)
        end
      end

      it 'leaves a comp whose date has not passed alone, and is a no-op run twice' do
        Plans::Manual.grant!(account, seats: 1, comp_expires_at: 5.days.from_now)

        CompExpiryJob.new.perform
        CompExpiryJob.new.perform

        expect(Plans.paid_or_better?(account.reload)).to be(true)
        expect(OperatorEvent.count).to eq(0)
      end

      it 'clears the date on a comp the customer replaced with a real subscription' do
        Plans::Manual.grant!(account, seats: 1, comp_expires_at: 2.days.from_now)
        account.account_subscription.update!(status: 'active', stripe_status: 'active',
                                             stripe_subscription_id: 'sub_bought')

        travel_to(3.days.from_now) do
          CompExpiryJob.new.perform

          expect(account.reload.account_subscription).to have_attributes(comp_expires_at: nil,
                                                                         access_state: 'active')
          expect(Plans.paid_or_better?(account)).to be(true)
        end
      end
    end
  end

  # --- 8. the audit log page --------------------------------------------------

  describe 'GET /operator/events' do
    before { sign_in(operator) }

    it 'lists every event newest first and filters by account and by action' do
      other = create(:account, name: 'Southgate Partners')
      create(:user, :admin, account: other)

      post suspend_operator_account_path(account), params: reason_params
      post suspend_operator_account_path(other), params: { reason: 'Second ticket, second account' }
      post lift_suspension_operator_account_path(account), params: { reason: 'Customer paid the invoice' }

      expect(OperatorEvent.count).to eq(3)

      get operator_events_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-operator-event-action="account.lift_suspension"')
      expect(response.body).to include('Customer paid the invoice')
      expect(response.body).not_to include('translation missing')

      get operator_events_path(account_id: other.id)

      expect(response.body).to include('Second ticket, second account')
      expect(response.body).not_to include('Customer paid the invoice')

      get operator_events_path(event_action: 'account.lift_suspension')

      expect(response.body).to include('Customer paid the invoice')
      expect(response.body).not_to include('Second ticket, second account')
    end

    it 'paginates' do
      20.times { |i| OperatorEvents.record!(operator:, action: 'account.suspend', account:, reason: "Row #{i}") }

      get operator_events_path

      expect(response).to have_http_status(:ok)

      get operator_events_path(page: 2)

      expect(response).to have_http_status(:ok)
    end

    it 'shows the last twenty on the account page with a link to the full log' do
      25.times { |i| OperatorEvents.record!(operator:, action: 'limits.update', account:, reason: "Row #{i}") }

      get operator_account_path(account)

      expect(response.body).to include('Row 24')
      expect(response.body).not_to include('Row 0')
      expect(response.body).to include(operator_events_path(account_id: account.id))
    end
  end

  # --- 9. the abuse queue -----------------------------------------------------

  describe 'GET /operator/abuse' do
    before { sign_in(operator) }

    def flag!(for_account = account, kind: 'fair_use_review', **rest)
      AbuseFlags.record!(for_account, kind, **rest)
    end

    it 'lists open flags newest first, filters by kind and account, and can show resolved ones' do
      fair_use = flag!(period: '2026-09', details: { completions: 900, threshold: 800 })
      other = create(:account, name: 'Southgate Partners')
      velocity = flag!(other, kind: 'send_velocity', period: '2026-09-04', details: { sends_today: 90, seats: 2 })
      resolved = flag!(kind: 'in_flight', period: '2026-09-03', details: { in_flight: 50, seats: 1 })
      resolved.update!(resolved_at: Time.current)

      get operator_abuse_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-operator-flag-row=\"#{fair_use.id}\"")
      expect(response.body).to include("data-operator-flag-row=\"#{velocity.id}\"")
      expect(response.body).not_to include("data-operator-flag-row=\"#{resolved.id}\"")
      expect(response.body).not_to include('translation missing')

      get operator_abuse_path(kind: 'send_velocity')

      expect(response.body).to include("data-operator-flag-row=\"#{velocity.id}\"")
      expect(response.body).not_to include("data-operator-flag-row=\"#{fair_use.id}\"")

      get operator_abuse_path(account_id: other.id)

      expect(response.body).to include("data-operator-flag-row=\"#{velocity.id}\"")
      expect(response.body).not_to include("data-operator-flag-row=\"#{fair_use.id}\"")

      get operator_abuse_path(resolved: 'true')

      expect(response.body).to include("data-operator-flag-row=\"#{resolved.id}\"")
    end

    it 'says how many flags are open in the console navigation' do
      flag!(period: '2026-09')
      flag!(kind: 'send_velocity', period: '2026-09-04')

      get operator_accounts_path

      expect(response.body).to include('data-operator-open-flags')
      expect(response.body).to match(/data-operator-open-flags[^>]*>\s*2\s*</)
    end

    # The one flag a person outside the account raised. The reported document
    # is shown; the signing link it names is NOT clickable, because opening it
    # would put the operator inside a signer's session.
    it 'shows a reported document with its template, signers and reason, and the slug as text only' do
      submission = create(:submission, :with_submitters, template: create(:template, account:, name: 'NDA 2026'))
      submitter = submission.submitters.first
      reported = AbuseFlags.record!(account, 'document_report', subject: submission,
                                                                details: { reason: 'phishing', details: 'Fake bank',
                                                                           ip: '203.0.113.9',
                                                                           submitter_slug: submitter.slug })

      get operator_abuse_path

      expect(response.body).to include("data-operator-flag-row=\"#{reported.id}\"")
      expect(response.body).to include('NDA 2026')
      expect(response.body).to include('phishing')
      expect(response.body).to include('Fake bank')
      expect(response.body).to include('203.0.113.9')
      expect(response.body).to include(submitter.slug)
      expect(response.body).not_to include("href=\"/s/#{submitter.slug}\"")
      expect(response.body).not_to include('translation missing')
    end

    describe 'resolving a flag' do
      let!(:flag) { AbuseFlags.record!(account, 'fair_use_review', period: '2026-09', details: { completions: 900 }) }

      it 'closes it with the reason on the row and writes the audit line' do
        post operator_resolve_abuse_flag_path(flag), params: reason_params

        expect(response).to redirect_to(operator_abuse_path)
        expect(flag.reload.resolved_at).to be_present
        expect(flag.details['resolution']).to eq('Ticket 4182 — customer asked')
        expect(last_event.action).to eq('abuse.resolve')
        expect(last_event.account_id).to eq(account.id)
        expect(last_event.subject).to eq(flag)
        expect(last_event.details).to include('kind' => 'fair_use_review')
      end

      it 'refuses without a reason, refuses a second time, and refuses a flag that is gone' do
        post operator_resolve_abuse_flag_path(flag)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_reason_required', count: 5))
        expect(flag.reload.resolved_at).to be_nil

        post operator_resolve_abuse_flag_path(flag), params: reason_params
        follow_redirect!
        post operator_resolve_abuse_flag_path(flag), params: reason_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_flag_resolved'))

        post operator_resolve_abuse_flag_path(id: flag.id + 10_000), params: reason_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_flag_missing'))
        expect(OperatorEvent.where(action: 'abuse.resolve').count).to eq(1)
      end
    end

    describe 'resuming sending from the queue' do
      before { SendingPause.pause!(account, reason: 'complaint', details: { email_event_id: 7, email: 'a@b.example' }) }

      let(:flag) { account.abuse_flags.where(kind: 'complaint').sole }

      it 'lifts the pause, and SendingPause resolves the flags of that pause with it' do
        expect(account.reload.sending_paused_at).to be_present

        post operator_resume_sending_abuse_flag_path(flag), params: reason_params

        expect(response).to redirect_to(operator_abuse_path)
        expect(account.reload.sending_paused_at).to be_nil
        expect(flag.reload.resolved_at).to be_present
        expect(last_event.action).to eq('sending.resume')
        expect(last_event.details).to include('from' => 'abuse_queue')
      end

      # The two decisions are deliberately separate: closing the flag is a
      # verdict on the flag, not permission to send again.
      it 'does not resume when the flag is merely resolved' do
        post operator_resolve_abuse_flag_path(flag), params: reason_params

        expect(flag.reload.resolved_at).to be_present
        expect(account.reload.sending_paused_at).to be_present
      end

      it 'refuses to resume an account that is not paused, and an internal account' do
        SendingPause.resume!(account)

        post operator_resume_sending_abuse_flag_path(flag), params: reason_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_not_paused'))

        internal = create(:account, :internal)
        internal_flag = AbuseFlags.record!(internal, 'fair_use_review', period: '2026-09')

        post operator_resume_sending_abuse_flag_path(internal_flag), params: reason_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_platform_account',
                                                 kind: Account::INTERNAL_KIND))
      end
    end
  end

  # --- 10. revenue, the Stripe inbox and adoption -----------------------------

  describe 'GET /operator/billing' do
    include_context 'with a Stripe test account'

    before { sign_in(operator) }

    def paying_row(seats, state, status = state)
      create(:account_subscription, account: create(:account), access_state: state, status:, seats:)
    end

    it 'adds up MRR over the states that actually collect, and nothing else' do
      paying_row(3, 'active')
      paying_row(2, 'past_due')
      paying_row(1, 'canceling', 'active')
      paying_row(5, 'trialing')
      paying_row(4, 'cancelled', 'canceled')
      Plans::Manual.grant!(create(:account, name: 'Comped Co'), seats: 7, comp_expires_at: 10.days.from_now)

      get operator_billing_path

      expect(response).to have_http_status(:ok)
      # 3 + 2 + 1 seats at $10; the trial, the cancellation and the seven
      # comped seats are all excluded.
      expect(response.body).to include(ActionController::Base.helpers.number_to_currency(60))
      expect(response.body).to include('data-revenue-mrr')
      expect(response.body).to include('6 seats')
      expect(response.body).to include('Comped Co')
      expect(response.body).not_to include('translation missing')
    end

    it 'counts trials, conversions, comps, refunds owed and cancellations of this month' do
      create(:account_subscription, account: create(:account), access_state: 'trialing', status: 'trialing',
                                    trial_used_at: Time.current, trial_end: 3.days.from_now)
      create(:account_subscription, account: create(:account), access_state: 'active', status: 'active',
                                    trial_used_at: 20.days.ago, trial_end: 2.days.ago)
      create(:account_subscription, account: create(:account), access_state: 'cancelled', status: 'canceled',
                                    ended_at: 1.day.ago)
      owed = create(:account_subscription, account: create(:account, name: 'Owed Co'), access_state: 'cancelled',
                                           status: 'canceled', refund_owed_subscription_id: 'sub_owed')

      get operator_billing_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-refund-owed-row=\"#{owed.account_id}\"")
      expect(response.body).to include('sub_owed')
      expect(response.body).to match(/data-revenue-conversions[^>]*>\s*1\s*</)
      expect(response.body).to match(/data-revenue-trials[^>]*>\s*1\s*</)
    end

    describe 'the Stripe event inbox' do
      def inbox_row(status:, event_type: 'customer.subscription.updated', attempts: 0, updated_at: Time.current,
                    error: nil)
        row = StripeEventInbox.create!(stripe_event_id: "evt_#{SecureRandom.hex(6)}", event_type:,
                                       payload: { id: 'evt', type: event_type }.to_json, status:, attempts:,
                                       last_error: error)
        row.update_columns(updated_at:)

        row
      end

      it 'defaults to the failed and processing rows and can be filtered to any status' do
        failed = inbox_row(status: 'failed', updated_at: 2.hours.ago, error: 'Stripe::APIError: boom')
        processing = inbox_row(status: 'processing', updated_at: 2.hours.ago)
        processed = inbox_row(status: 'processed')

        get operator_billing_path

        expect(response.body).to include("data-operator-inbox-row=\"#{failed.id}\"")
        expect(response.body).to include("data-operator-inbox-row=\"#{processing.id}\"")
        expect(response.body).not_to include("data-operator-inbox-row=\"#{processed.id}\"")
        expect(response.body).to include('Stripe::APIError: boom')

        get operator_billing_path(status: ['processed'])

        expect(response.body).to include("data-operator-inbox-row=\"#{processed.id}\"")
        expect(response.body).not_to include("data-operator-inbox-row=\"#{failed.id}\"")
      end

      it 'retries a failed row, releases a stale claim first, and refuses a terminal or in-flight one' do
        failed = inbox_row(status: 'failed', updated_at: 2.hours.ago, attempts: 1)

        expect do
          post operator_retry_stripe_event_path(failed), params: reason_params
        end.to change { ProcessStripeEventJob.jobs.size }.by(1)

        expect(response).to redirect_to(operator_billing_path)
        expect(last_event.action).to eq('stripe.retry_event')
        expect(last_event.details).to include('was' => 'failed', 'event_type' => 'customer.subscription.updated')

        follow_redirect!

        stale = inbox_row(status: 'processing', updated_at: 2.hours.ago)

        post operator_retry_stripe_event_path(stale), params: reason_params
        follow_redirect!

        expect(stale.reload.status).to eq('failed')
        expect(stale.last_error).to eq(StripeReconciliationJob::STALE_CLAIM_NOTE)

        processed = inbox_row(status: 'processed')

        post operator_retry_stripe_event_path(processed), params: reason_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_event_terminal', status: 'processed'))

        fresh = inbox_row(status: 'processing')

        post operator_retry_stripe_event_path(fresh), params: reason_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_event_in_flight'))
        expect(fresh.reload.status).to eq('processing')
      end

      # Review 1 M4 / Codex. The button is only drawn for a row the model's
      # own scopes call stuck; the DOOR used to accept any `failed` row, so a
      # kept link or a double submit started a second Sidekiq chain for an
      # event the first one still owned.
      it 'refuses a failed row Sidekiq still owns, and takes it once the window has passed' do
        recent = inbox_row(status: 'failed', updated_at: 2.minutes.ago, attempts: 1)

        expect do
          post operator_retry_stripe_event_path(recent), params: reason_params
        end.not_to(change { ProcessStripeEventJob.jobs.size })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_event_in_flight'))
        expect(OperatorEvent.where(action: 'stripe.retry_event').count).to eq(0)

        recent.update_columns(updated_at: (StripeEventInbox::RETRY_AFTER + 1.minute).ago)

        expect do
          post operator_retry_stripe_event_path(recent), params: reason_params
        end.to change { ProcessStripeEventJob.jobs.size }.by(1)
      end

      it 'refuses a failed row that has spent every attempt' do
        exhausted = inbox_row(status: 'failed', updated_at: 2.hours.ago,
                              attempts: StripeEventInbox::MAX_ATTEMPTS)

        expect do
          post operator_retry_stripe_event_path(exhausted), params: reason_params
        end.not_to(change { ProcessStripeEventJob.jobs.size })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_event_exhausted',
                                                 count: StripeEventInbox::MAX_ATTEMPTS))
      end

      # The release is a conditional write, not a read followed by a write: a
      # worker that took the claim between the two keeps it, and the console
      # says so rather than pulling the row out from under it.
      it 'leaves a claim a live worker re-took, and refuses' do
        stale = inbox_row(status: 'processing', updated_at: 2.hours.ago)

        allow(Operator::BillingController).to receive(:release_claim!) do |inbox|
          inbox.update_columns(updated_at: Time.current)

          StripeReconciliationJob.release_stale_claims!(StripeEventInbox.stale_claims.where(id: inbox.id))
        end

        expect do
          post operator_retry_stripe_event_path(stale), params: reason_params
        end.not_to(change { ProcessStripeEventJob.jobs.size })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_event_in_flight'))
        expect(stale.reload.status).to eq('processing')
        expect(stale.last_error).to be_nil
        expect(OperatorEvent.where(action: 'stripe.retry_event').count).to eq(0)
      end
    end

    describe 'the reconciliation report and adoption' do
      let(:target) { create(:account, name: 'Unlinked Co') }

      def store_report!(unlinked: [], manual_refunds: [], stopped_after: nil, vanished_skipped: [])
        report = StripeReconciliationJob::Report.new(
          repaired: [], errors: [], requeued: 0, duplicates: [], foreign: [], unlinked:, settled: [],
          manual_refunds:, vanished: [], vanished_skipped:, key_mismatch: nil, rows: 4, stopped_after:
        )

        StripeReconciliationState.record_report!(report)
      end

      # The subscription the row is currently holding, as Stripe sees it now:
      # what the locked re-read asks for before it will let go of it.
      def stub_held(id, fixture)
        body = JSON.parse(fixture_body(fixture)).merge('id' => id)

        stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{Regexp.escape(id)}})
          .to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      def stub_adoptable(id, metadata: nil)
        body = JSON.parse(fixture_body('subscription-active')).merge('id' => id)
        body['metadata'] = metadata.stringify_keys if metadata

        stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{Regexp.escape(id)}})
          .to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      after { StripeReconciliationState.delete(StripeReconciliationState::REPORT_KEY) }

      it 'renders the last report, its manual-review rows and its budget warning' do
        store_report!(unlinked: [{ account_id: target.id, customer: customer_a, subscription: subscription_b }],
                      manual_refunds: [{ account_id: target.id, cancelled: subscription_a, note: 'paused survivor' }],
                      stopped_after: 41)

        get operator_billing_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("data-unlinked-row=\"#{subscription_b}\"")
        expect(response.body).to include("data-manual-review-row=\"#{subscription_a}\"")
        expect(response.body).to include('paused survivor')
        expect(response.body).to include('data-reconciliation-budget')
        expect(response.body).not_to include('translation missing')
      end

      it 'adopts an unlinked subscription into the account through the Linker' do
        create(:account_subscription, account: target, access_state: 'cancelled', status: 'none',
                                      stripe_customer_id: customer_a)
        stub_adoptable(subscription_b)

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to redirect_to(operator_billing_path)

        row = target.reload.account_subscription

        expect(row.stripe_subscription_id).to eq(subscription_b)
        expect(row.access_state).to eq('active')
        expect(last_event.action).to eq('stripe.adopt')
        expect(last_event.account_id).to eq(target.id)
        expect(last_event.details).to include('subscription' => subscription_b)
      end

      # Review 1 H1 / Codex H2. `ours?` is true for anything on our price, so
      # it cannot answer "does this belong to THIS account". Our own Checkout
      # writes the account id onto the subscription, and that tag is the only
      # thing that can — one wrong digit in the form used to move a live
      # paying subscription onto another tenant.
      it 'refuses a subscription our Checkout tagged for a different account' do
        payer = create(:account, name: 'Payer Co')
        create(:account_subscription, account: target, access_state: 'cancelled', status: 'none',
                                      stripe_customer_id: customer_a)
        stub_adoptable(subscription_b, metadata: { StripeBilling::SubscriptionPolicy::ACCOUNT_TAG_KEY =>
                                                     payer.id.to_s })

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_adopt_tagged_elsewhere', account_id: payer.id))
        expect(target.reload.account_subscription.stripe_subscription_id).to be_nil
        expect(Plans.key_for(target)).to eq(Plans::FREE)
        expect(OperatorEvent.where(action: 'stripe.adopt').count).to eq(0)
      end

      it "refuses when the subscription's Stripe customer belongs to another account" do
        holder = create(:account, name: 'Customer Holder Co')
        create(:account_subscription, account: holder, access_state: 'active', status: 'active',
                                      stripe_customer_id: customer_a)
        stub_adoptable(subscription_b)

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_adopt_customer_taken', account_id: holder.id))
        expect(OperatorEvent.where(action: 'stripe.adopt').count).to eq(0)
      end

      it 'refuses when the account already bills through a different Stripe customer' do
        create(:account_subscription, account: target, access_state: 'cancelled', status: 'none',
                                      stripe_customer_id: customer_b)
        stub_adoptable(subscription_b)

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_adopt_customer_mismatch',
                                                 customer: customer_a, own: customer_b))
        expect(target.reload.account_subscription.stripe_subscription_id).to be_nil
      end

      # B-L6 (review 1), confirmed rather than assumed: EVERY refusal of an
      # adoption onto an account that has never bought anything leaves the
      # account exactly as it was. The row the Linker needs is created inside
      # the action's transaction, so a refusal — from the pre-checks, from
      # Stripe's answer, or from the locked re-read — takes it away again.
      # An empty `cancelled/none` subscription row left behind would be a row
      # the billing page and the reconciliation sweep both have to explain.
      it 'leaves no half-made subscription row behind, whichever refusal it meets' do
        stub_adoptable(subscription_b, metadata: { StripeBilling::SubscriptionPolicy::ACCOUNT_TAG_KEY =>
                                                     create(:account, name: 'Payer Co').id.to_s })

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to have_http_status(:unprocessable_content)
        expect(target.reload.account_subscription).to be_nil

        # And a refusal from Stripe itself, which is raised further in.
        stub_request(:get, %r{\Ahttps://api\.stripe\.com/v1/subscriptions/#{Regexp.escape(subscription_b)}})
          .to_return(status: 404, body: { error: { code: 'resource_missing', type: 'invalid_request_error' } }.to_json,
                     headers: { 'Content-Type' => 'application/json' })

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to have_http_status(:unprocessable_content)
        expect(target.reload.account_subscription).to be_nil
        expect(OperatorEvent.where(action: 'stripe.adopt').count).to eq(0)
      end

      # Untagged, on a customer no account holds: nothing proves whose it is,
      # so the operator has to say out loud that they have checked — and the
      # refusal leaves no half-made subscription row behind.
      it 'refuses an unprovable subscription until it is confirmed, then records the confirmation' do
        stub_adoptable(subscription_b)

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_adopt_needs_confirmation'))
        expect(target.reload.account_subscription).to be_nil

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b, confirm_untagged: '1')

        expect(response).to redirect_to(operator_billing_path)
        expect(target.reload.account_subscription.stripe_subscription_id).to eq(subscription_b)
        expect(last_event.action).to eq('stripe.adopt')
        expect(last_event.details).to include('confirmed_untagged' => true)
      end

      # Review 1 loop 2. The headline finding of the nightly sweep is "this
      # customer has a live subscription of ours that no row names" — and the
      # row it names ALWAYS still holds its own, dead subscription id, because
      # a downgrade never deletes the money history (D43). Refusing that was
      # refusing the one case the Adopt button exists for.
      it 'replaces a subscription Stripe has finished with, and records what it replaced' do
        row = create(:account_subscription, account: target, access_state: 'cancelled', status: 'canceled',
                                            stripe_subscription_id: subscription_a, stripe_customer_id: customer_a)
        stub_held(subscription_a, 'subscription-canceled')
        stub_adoptable(subscription_b)

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to redirect_to(operator_billing_path)
        expect(row.reload.stripe_subscription_id).to eq(subscription_b)
        expect(row.access_state).to eq('active')
        expect(Plans.key_for(target.reload)).to eq(Plans::PAID)
        expect(last_event.action).to eq('stripe.adopt')
        expect(last_event.details).to include('replaced' => subscription_a)
      end

      # And the line that keeps it safe: a subscription that is still ALIVE is
      # the duplicate question — it moves money and it belongs to the survivor
      # policy, never to an account number typed into a form.
      it 'refuses to replace a subscription that is still live, and cancels nothing' do
        row = create(:account_subscription, account: target, access_state: 'active', status: 'active',
                                            stripe_subscription_id: subscription_a, stripe_customer_id: customer_a)
        stub_held(subscription_a, 'subscription-active')

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_adopt_already_linked', id: subscription_a))
        expect(row.reload.stripe_subscription_id).to eq(subscription_a)
        expect(OperatorEvent.where(action: 'stripe.adopt').count).to eq(0)
        expect(a_request(:delete, /api\.stripe\.com/)).not_to have_been_made
      end

      # Review 1 H3 / Codex H3. Adopting an id the row already holds used to
      # fall into the Linker's apply_current! branch: Stripe's state (paid
      # access and all) was written, the console then called it a refusal, and
      # no audit row was written for the change that stood.
      it 'refuses a repeat adoption of the same subscription without touching Stripe or the row' do
        row = create(:account_subscription, account: target, access_state: 'cancelled', status: 'none',
                                            stripe_subscription_id: subscription_b, stripe_customer_id: customer_a)

        post operator_adopt_stripe_subscription_path,
             params: reason_params(account_id: target.id, subscription_id: subscription_b)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_adopt_holds_this', id: subscription_b))
        expect(row.reload.access_state).to eq('cancelled')
        expect(Plans.key_for(target.reload)).to eq(Plans::FREE)
        expect(OperatorEvent.where(action: 'stripe.adopt').count).to eq(0)
        expect(a_request(:get, /api\.stripe\.com/)).not_to have_been_made
      end

      it 'refuses every account it cannot be sure of, and writes nothing' do
        internal = create(:account, :internal)
        leaving = create(:account, name: 'Leaving Co')
        leaving.update!(deletion_requested_at: Time.current, purge_scheduled_for: 90.days.from_now)
        linked = create(:account, name: 'Linked Co')
        create(:account_subscription, account: linked, access_state: 'active', status: 'active',
                                      stripe_subscription_id: subscription_a, stripe_customer_id: customer_a)
        # Still live at Stripe, so the row will not let go of it.
        stub_held(subscription_a, 'subscription-active')

        [[{ account_id: 0, subscription_id: subscription_b },
          escaped('operator_refused_adopt_no_account', id: 0)],
         [{ account_id: internal.id, subscription_id: subscription_b },
          escaped('operator_refused_platform_account', kind: Account::INTERNAL_KIND)],
         [{ account_id: leaving.id, subscription_id: subscription_b },
          escaped('operator_refused_adopt_pending_deletion')],
         [{ account_id: target.id, subscription_id: '' },
          escaped('operator_refused_adopt_no_subscription')],
         [{ account_id: linked.id, subscription_id: subscription_b },
          escaped('operator_refused_adopt_already_linked', id: subscription_a)],
         [{ account_id: target.id, subscription_id: subscription_a },
          escaped('operator_refused_adopt_taken', id: linked.id)]].each do |params, message|
          post operator_adopt_stripe_subscription_path, params: reason_params(params)

          expect(response).to have_http_status(:unprocessable_content), params.inspect
          expect(response.body).to include(message), params.inspect
        end

        expect(OperatorEvent.where(action: 'stripe.adopt').count).to eq(0)
        expect(target.reload.account_subscription&.stripe_subscription_id).to be_nil
        expect(linked.reload.account_subscription.stripe_subscription_id).to eq(subscription_a)
      end

      it 'refuses without a reason' do
        post operator_adopt_stripe_subscription_path,
             params: { account_id: target.id, subscription_id: subscription_b }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(escaped('operator_refused_reason_required', count: 5))
      end
    end
  end

  # --- 11. provisioning -------------------------------------------------------

  describe 'GET /operator/provisioning' do
    before { sign_in(operator) }

    it 'lists provisioning events across accounts and searches by email and key' do
      first = ProvisioningEvent.create!(account:, email: 'jane@northfield.example', idempotency_key: 'key-abc')
      other = create(:account, name: 'Southgate Partners')
      second = ProvisioningEvent.create!(account: other, email: 'ravi@southgate.example', idempotency_key: 'key-xyz')

      get operator_provisioning_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-provisioning-event-row=\"#{first.id}\"")
      expect(response.body).to include("data-provisioning-event-row=\"#{second.id}\"")
      expect(response.body).not_to include('translation missing')

      get operator_provisioning_path(q: 'ravi@southgate')

      expect(response.body).to include("data-provisioning-event-row=\"#{second.id}\"")
      expect(response.body).not_to include("data-provisioning-event-row=\"#{first.id}\"")

      get operator_provisioning_path(q: 'key-abc')

      expect(response.body).to include("data-provisioning-event-row=\"#{first.id}\"")
      expect(response.body).not_to include("data-provisioning-event-row=\"#{second.id}\"")
    end

    it 'lists moves, invitations by state with parked purchases highlighted, and seat drift' do
      other = create(:account, name: 'Southgate Partners')
      mover = create(:user, account: other)
      move = AccountMove.create!(from_account: account, to_account: other, user: mover)
      pending = create(:account_invite, account:, email: 'new@northfield.example')
      parked = create(:account_invite, account:, email: 'parked@northfield.example',
                                       payment_pending_until: 2.days.from_now, pending_quantity: 3)
      drifting = create(:account_subscription, account: other, access_state: 'active', status: 'active',
                                               seats: 9, stripe_subscription_id: 'sub_drift',
                                               stripe_item_id: 'si_drift')

      get operator_provisioning_path

      expect(response.body).to include("data-move-row=\"#{move.id}\"")
      expect(response.body).to include("data-platform-invite-row=\"#{pending.id}\"")
      expect(response.body).not_to include("data-platform-invite-row=\"#{parked.id}\"")
      expect(response.body).to include("data-seat-drift-row=\"#{drifting.account_id}\"")
      expect(response.body).to include('billing 9')

      get operator_provisioning_path(invite_state: 'payment_pending')

      expect(response.body).to include("data-platform-invite-row=\"#{parked.id}\"")
      expect(response.body).to include('data-parked-purchase')
      expect(response.body).not_to include("data-platform-invite-row=\"#{pending.id}\"")
    end

    # Review 1 M3. Seat occupancy used to be counted one account at a time —
    # three or four queries per row, up to two hundred rows — which is the one
    # N+1 the console had left. It is one grouped count now, so the number of
    # queries does not grow with the number of drifting subscriptions.
    it 'counts the seats of every drifting subscription without a query per row' do
      drifting = Array.new(6) do |i|
        account = create(:account, name: "Drifting #{i}")
        create(:user, account:)
        create(:account_subscription, account:, access_state: 'active', status: 'active', seats: 9,
                                      stripe_subscription_id: "sub_drift_#{i}", stripe_item_id: "si_drift_#{i}")
      end

      seat_queries = 0
      counter = lambda { |_name, _start, _finish, _id, payload|
        seat_queries += 1 if payload[:sql].to_s.include?('FROM "users"')
      }

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get operator_provisioning_path }

      expect(response).to have_http_status(:ok)
      drifting.each { |row| expect(response.body).to include("data-seat-drift-row=\"#{row.account_id}\"") }
      expect(seat_queries).to be <= 2
    end
  end

  # --- 12. the scheduler ------------------------------------------------------

  describe 'GET /operator/scheduler' do
    before { sign_in(operator) }

    it 'shows every scheduled job, its cron line, its last run and what it said' do
      # The stamp is handed to the page rather than written through Redis: the
      # Redis round-trip is spec/golden/scheduler_spec.rb's subject, and that
      # file deletes these very keys, so reading them here couples two spec
      # files through a shared server. What is asserted here is the PAGE.
      allow(SchedulerStamps).to receive(:all).and_return(
        'stripe_reconciliation' => { 'started_at' => '2026-09-04T06:00:00Z',
                                     'finished_at' => '2026-09-04T06:00:12Z', 'duration_ms' => 12_000,
                                     'outcome' => 'error', 'error' => 'Stripe::APIError: gateway' },
        'billing_lifecycle' => nil, 'account_retention' => nil, 'comp_expiry' => nil,
        'scheduler_heartbeat' => nil
      )

      get operator_scheduler_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-scheduler-row="stripe_reconciliation"')
      expect(response.body).to include('data-scheduler-row="comp_expiry"')
      expect(response.body).to include('data-scheduler-row="scheduler_heartbeat"')
      expect(response.body).to include('0 6 * * *')
      expect(response.body).to include('Stripe::APIError: gateway')
      expect(response.body).to include('data-scheduler-outcome="error"')
      expect(response.body).to include('data-scheduler-outcome="never"')
      expect(response.body).not_to include('data-stamps-unavailable')
      expect(response.body).not_to include('translation missing')
    end

    it 'queues a business job on demand and writes the audit line' do
      post operator_run_scheduler_job_path, params: reason_params(job: 'stripe_reconciliation')

      expect(response).to redirect_to(operator_scheduler_path)
      expect(Sidekiq::Queues.jobs_by_queue.values.flatten.to_json).to include('StripeReconciliationJob')
      expect(last_event.action).to eq('scheduler.run_now')
      expect(last_event.account_id).to be_nil
      expect(last_event.details).to include('job' => 'stripe_reconciliation')
    end

    # Review 1 M6. The scheduler tab answers "is the clock alive?", which is
    # the question asked during exactly the incident that takes Redis with it.
    it 'still renders when the stamp store cannot be read, and says so' do
      allow(Sidekiq).to receive(:redis).and_raise(StandardError.new('redis down'))
      allow(ErrorReport).to receive(:error)

      expect(SchedulerStamps.all).to eq({})

      get operator_scheduler_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-stamps-unavailable')
      expect(response.body).to include('data-scheduler-row="stripe_reconciliation"')
      expect(response.body).not_to include('translation missing')
    end

    it 'refuses the heartbeat, an unknown job, and a run with no reason' do
      post operator_run_scheduler_job_path, params: reason_params(job: 'scheduler_heartbeat')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(escaped('operator_refused_job_heartbeat'))

      post operator_run_scheduler_job_path, params: reason_params(job: 'AccountPurgeJob')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(escaped('operator_refused_job_unknown'))

      post operator_run_scheduler_job_path, params: { job: 'stripe_reconciliation' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Sidekiq::Queues.jobs_by_queue.values.flatten.to_json).not_to include('StripeReconciliationJob')
      expect(OperatorEvent.where(action: 'scheduler.run_now').count).to eq(0)
    end
  end

  # --- 13. platform settings --------------------------------------------------

  describe 'operator settings' do
    before { sign_in(operator) }

    it 'shows the alert address, the deployment switches and no secret at all' do
      ENV['STRIPE_SECRET_KEY'] = 'sk_test_fake'

      get operator_settings_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(Docuseal::SUPPORT_EMAIL)
      expect(response.body).to include('data-stripe-key="STRIPE_SECRET_KEY"')
      expect(response.body).not_to include('sk_test_fake')
      expect(response.body).to include('data-switch="registration"')
      expect(response.body).to include('data-switch="postmark"')
      expect(response.body).to include('data-certificate-fingerprint')
      expect(response.body).not_to include('translation missing')
    ensure
      ENV.delete('STRIPE_SECRET_KEY')
    end

    it 'sets the alert address, clears it back to the support mailbox, and writes both audit lines' do
      patch operator_settings_path, params: reason_params(operator_alert_email: 'alerts@processorteam.com')

      expect(response).to redirect_to(operator_settings_path)
      expect(OperatorAlert.address).to eq('alerts@processorteam.com')
      expect(last_event.action).to eq('settings.update')
      expect(last_event.details).to include('after' => 'alerts@processorteam.com')

      patch operator_settings_path, params: reason_params(operator_alert_email: '')

      expect(OperatorAlert.address).to eq(Docuseal::SUPPORT_EMAIL)
      expect(last_event.details).to include('before' => 'alerts@processorteam.com', 'after' => nil)
    end

    it 'refuses an address that is not one, and a change with no reason' do
      patch operator_settings_path, params: reason_params(operator_alert_email: 'not-an-address')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(escaped('operator_refused_alert_email_invalid'))
      expect(OperatorAlert.address).to eq(Docuseal::SUPPORT_EMAIL)

      patch operator_settings_path, params: { operator_alert_email: 'alerts@processorteam.com' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(OperatorConfigs.fetch(OperatorAlert::EMAIL_KEY)).to be_blank
      expect(OperatorEvent.where(action: 'settings.update').count).to eq(0)
    end

    # B-L5 (review 1). Setting an address on a deployment that has never been
    # seeded says "run rake operator:seed"; CLEARING one used to answer
    # "Settings saved" having done nothing at all — and leave an audit row
    # claiming the change. Both ways round now tell the same truth.
    it 'says so when there is no operator account to store the setting on' do
      allow(OperatorConfigs).to receive(:account).and_return(nil)

      ['alerts@processorteam.com', ''].each do |address|
        patch operator_settings_path, params: reason_params(operator_alert_email: address)

        expect(response).to have_http_status(:unprocessable_content), address.inspect
        expect(response.body).to include(escaped('operator_refused_no_operator_account'))
        expect(OperatorEvent.where(action: 'settings.update').count).to eq(0)
      end
    end
  end

  # --- 14. the console link ---------------------------------------------------

  describe 'the navbar entry' do
    it 'is shown to an operator and to nobody else' do
      sign_in(operator)
      get operator_accounts_path
      expect(response.body).to include('id="operator_console_button"')

      sign_in(account_admin)
      get settings_profile_index_path
      expect(response.body).not_to include('id="operator_console_button"')
      expect(response.body).not_to include('/operator/accounts')
    end
  end
end
