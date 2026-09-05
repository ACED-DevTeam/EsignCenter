# frozen_string_literal: true

# Support impersonation (Session 8, phase C): an operator looking at a
# customer's account as one of its people.
#
# This is the most dangerous thing the platform can do, so the claims pinned
# here are the ones that make it safe rather than the ones that make it work:
#
#   1. Getting in costs a reason the customer will read and a live
#      authenticator code, and a list of people can never be viewed as at all.
#   2. Read-only means read-only, proved by sweeping EVERY write route in the
#      application off the route table — a door added next month is covered by
#      this spec the moment it is routed.
#   3. The forbidden families — money, people, credentials, configuration and
#      signing — stay shut in edit mode too, and the pages that print a
#      credential stay shut in both.
#   4. Nothing happens without an audit row, the customer is told by email and
#      can see the history on their own settings page, and the session always
#      ends: by hand, by signing out, or on the clock.
RSpec.describe 'Support impersonation', type: :request do
  def enroll_two_factor(user)
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)

    user
  end

  let(:operator_account) { create(:account, :operator) }
  let(:operator) { enroll_two_factor(create(:user, :admin, account: operator_account, platform_operator: true)) }
  let(:account) { create(:account, name: 'Northfield Legal') }
  let!(:admin) { create(:user, :admin, account:, email: 'jane@northfield.example') }

  let(:reason) { 'Ticket 4182 — the customer cannot open their onboarding template' }

  def start!(user: admin, mode: SupportImpersonation::READ_ONLY_MODE, reason: self.reason, code: nil)
    post operator_impersonations_path,
         params: { account_id: account.id, user_id: user.id, mode:, reason:,
                   otp_attempt: code || operator.reload.current_otp }
  end

  def session_state
    request.session[SupportImpersonation::SESSION_KEY]
  end

  def last_event
    OperatorEvent.newest_first.first
  end

  def events(action)
    OperatorEvent.where(action:).newest_first
  end

  # --- 1. getting in ----------------------------------------------------------

  describe 'the start door' do
    it 'does not exist for anybody who is not an enrolled operator' do
      [nil, admin, create(:user, :admin, account: create(:account, :internal))].each do |user|
        sign_in(user) if user

        expect { start! }.to raise_error(ActionController::RoutingError)
        expect(OperatorEvent.count).to eq(0)

        sign_out(user) if user
      end
    end

    it 'starts a read-only session, records it, tells the customer and lands on their dashboard' do
      sign_in(operator)

      expect { start! }.to change { events('impersonation.start').count }.by(1)

      expect(response).to redirect_to(root_path)

      event = events('impersonation.start').first
      expect(event.account).to eq(account)
      expect(event.subject).to eq(admin)
      expect(event.operator).to eq(operator)
      expect(event.reason).to eq(reason)
      expect(event.details).to include('mode' => SupportImpersonation::READ_ONLY_MODE,
                                       'user_email' => admin.email)
      expect(event.ip).to be_present

      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(session_state).to include('mode' => SupportImpersonation::READ_ONLY_MODE,
                                       'account_id' => account.id, 'user_id' => admin.id,
                                       'reason' => reason, 'event_id' => event.id)
      expect(response.body).to include('data-support-impersonation-banner')
      expect(response.body).to include(ERB::Util.html_escape(reason))
    end

    it 'emails the account administrators, and never an internal account' do
      other_admin = create(:user, :admin, account:, email: 'sam@northfield.example')
      create(:user, :viewer, account:, email: 'viewer@northfield.example')

      sign_in(operator)
      start!

      Sidekiq::Worker.drain_all

      mail = ActionMailer::Base.deliveries.last
      expect(ActionMailer::Base.deliveries.map { |m| m.to.first })
        .to contain_exactly(admin.email, other_admin.email)
      expect(mail.subject).to eq('EsignCenter support opened your account')
      expect(mail.body.encoded).to include(admin.email)
      expect(mail.body.encoded).to include('Ticket 4182')

      # One message per person, never the roster in the To header.
      expect(ActionMailer::Base.deliveries.map { |m| m.to.size }.uniq).to eq([1])
    end

    it 'writes the history row for an internal account but sends no mail' do
      internal = create(:account, :internal, name: 'Processor Team')
      internal_admin = create(:user, :admin, account: internal)

      sign_in(operator)
      post operator_impersonations_path,
           params: { account_id: internal.id, user_id: internal_admin.id, reason:,
                     otp_attempt: operator.reload.current_otp }

      # An internal account is not actionable by the console at all, so the
      # start is refused before any of this — the mail rule is asserted by the
      # customer example above, and this is the refusal.
      expect(response).to redirect_to(operator_account_path(internal))
      expect(flash[:alert]).to eq(I18n.t('operator_refused_platform_account', kind: internal.account_kind))
      expect(OperatorEvent.count).to eq(0)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'refuses a blank, a wrong and an already-used authenticator code' do
      sign_in(operator)

      ['', '000000'].each do |code|
        start!(code:)

        expect(response).to redirect_to(operator_account_path(account))
        expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_code'))
      end

      code = operator.reload.current_otp
      start!(code:)
      expect(response).to redirect_to(root_path)

      delete operator_current_impersonation_path

      start!(code:)
      expect(response).to redirect_to(operator_account_path(account))
      expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_code'))
      expect(events('impersonation.start').count).to eq(1)
    end

    it 'refuses a reason that is not a sentence' do
      sign_in(operator)
      start!(reason: 'ticket')

      expect(response).to redirect_to(operator_account_path(account))
      expect(flash[:alert]).to eq(
        I18n.t('operator_impersonation_refused_reason', count: SupportImpersonation::MINIMUM_REASON_LENGTH)
      )
      expect(OperatorEvent.count).to eq(0)
    end

    it 'refuses a mode it does not know' do
      sign_in(operator)
      start!(mode: 'everything')

      expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_mode'))
      expect(OperatorEvent.count).to eq(0)
    end

    it 'refuses every person who must never be viewed as' do
      archived = create(:user, account:, archived_at: Time.current)
      integration = create(:user, account:, role: 'integration')
      operator_user = create(:user, :admin, account: operator_account, platform_operator: true)

      sign_in(operator)

      {
        archived => 'operator_impersonation_refused_archived',
        integration => 'operator_impersonation_refused_integration'
      }.each do |user, key|
        start!(user:)

        expect(flash[:alert]).to eq(I18n.t(key)), "#{key} was not the refusal"
      end

      # Somebody in the operator's own account: the account itself is refused
      # before the person is even looked at.
      post operator_impersonations_path,
           params: { account_id: operator_account.id, user_id: operator_user.id, reason:,
                     otp_attempt: operator.reload.current_otp }
      expect(flash[:alert]).to eq(
        I18n.t('operator_refused_platform_account', kind: operator_account.account_kind)
      )

      # A platform operator who happens to sit in a customer account.
      flagged = create(:user, :admin, account:, platform_operator: true)
      start!(user: flagged)
      expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_operator_user'))

      expect(OperatorEvent.count).to eq(0)
    end

    it 'refuses a purged account' do
      account.update!(purged_at: Time.current)

      sign_in(operator)
      start!

      expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_purged'))
      expect(OperatorEvent.count).to eq(0)
    end

    it 'refuses a second session while one is running' do
      sign_in(operator)
      start!

      other = create(:user, :admin, account:, email: 'sam@northfield.example')
      start!(user: other)

      expect(response).to redirect_to(operator_account_path(account))
      expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_already_active'))
      expect(events('impersonation.start').count).to eq(1)
      expect(session_state['user_id']).to eq(admin.id)
    end
  end

  # --- 2. test mode ------------------------------------------------------------

  describe 'test mode and support sessions never overlap' do
    it 'stops test mode when a support session starts, and refuses test mode while one is running' do
      sign_in(operator)

      post testing_account_path
      expect(request.session[:impersonated_user_id]).to be_present
      testing_user_id = request.session[:impersonated_user_id]

      start!

      expect(response).to redirect_to(root_path)
      expect(request.session[:impersonated_user_id]).to eq(admin.uuid)
      expect(request.session[:impersonated_user_id]).not_to eq(testing_user_id)

      post testing_account_path

      expect(response).to have_http_status(:forbidden)
      expect(events('impersonation.refused').first.details['target']).to eq('testing_accounts#create')
      expect(request.session[:impersonated_user_id]).to eq(admin.uuid)
    end
  end

  # --- 3. the sweep -------------------------------------------------------------

  describe 'read-only enforcement, swept off the route table' do
    # Every write route in the application, with a placeholder standing in for
    # each id: the refusal happens before any controller looks at one, so what
    # the id points at is irrelevant.
    def write_routes
      Rails.application.routes.routes.filter_map do |route|
        controller = route.defaults[:controller].to_s

        next if controller.blank?
        next unless route.verb.to_s.match?(/POST|PUT|PATCH|DELETE/)
        next if controller.start_with?('api/')

        path = route.path.spec.to_s.sub('(.:format)', '')
        next if path.include?('*')

        # A route can answer to more than one verb (`get|post /mcp`); the
        # write one is the one this rule is about.
        verb = route.verb.to_s.split('|').find { |candidate| %w[POST PUT PATCH DELETE].include?(candidate) }

        [verb.downcase.to_sym, path.gsub(/:[a-z_]+/, '1'), "#{controller}##{route.defaults[:action]}"]
      end.uniq
    end

    # The doors this rule does not own, and the reason for each. They are not
    # skipped quietly: the example below asserts that none of them can be
    # driven to a success by a support session either.
    let(:not_this_rule) do
      {
        'active_storage/direct_uploads#create' =>
          'ActiveStorage has its own base controller, outside ApplicationController. The blob it makes is ' \
          'inert until a document controller attaches it, and that door is swept below.',
        'active_storage/disk#update' => 'the same: ActiveStorage’s own controller, and a signed one-shot token',
        'sessions#create' => 'Devise prepends require_no_authentication: a signed-in browser never reaches it',
        'registrations#create' => 'the same Devise gate',
        'confirmations#create' => 'the same Devise gate',
        'passwords#create' => 'the same Devise gate',
        'invitations#update' => 'the same Devise gate',
        'omniauth_callbacks#passthru' => 'the same Devise gate',
        'omniauth_callbacks#google_oauth2' => 'the same Devise gate',
        'mcp#call' =>
          'the MCP door is ActionController::API and token-authenticated: it has no session for a support ' \
          'session to ride in on, which is why the spec says MCP is unaffected. It answers 401 without a token.',
        'postmark_webhooks#create' =>
          'a provider endpoint on ActionController::API — no session, no cookie and no current_user for a ' \
          'support session to ride in on; it is guarded by basic auth and an IP allowlist instead.',
        'template_folders#destroy' =>
          'a dead route: TemplateFoldersController has no destroy action, so Rails answers before any ' \
          'controller callback runs. Nothing to guard, and nothing that could ever succeed.'
      }
    end

    # Every controller with a write route has to be classified in
    # SupportImpersonation::CLASSIFICATION, so a new one fails here until
    # somebody has decided which side of the line it is on.
    it 'classifies every controller in the application that has a write route' do
      # The operator's own console is excluded on purpose: `console?` keys on
      # the path prefix, so a console tab added later needs no entry. Every
      # other name is mapped through the controller class, because the rule is
      # handed the RUNTIME `controller_path` and a couple of those differ from
      # the name in the route table — a classification keyed on the wrong one
      # would be documentation that does nothing.
      controllers = write_routes.map { |_verb, _path, target| target.split('#').first }
                                .uniq.reject { |name| SupportImpersonation.console?(name) }
                                .map { |name| "#{name}_controller".camelize.constantize.controller_path }

      expect(controllers).to match_array(SupportImpersonation::CLASSIFICATION.keys)
    end

    it 'refuses every write door, with an audit row for each' do
      sign_in(operator)
      start!

      swept = 0

      write_routes.each do |verb, path, target|
        next if target.start_with?('operator/')
        next if target == 'sessions#destroy'
        next if not_this_rule.key?(target)

        public_send(verb, path)

        expect(response).to have_http_status(:forbidden),
                            "#{verb.upcase} #{path} (#{target}) answered #{response.status}"

        event = last_event
        expect(event.action).to eq('impersonation.refused'), "#{target} was refused with no audit row"
        expect(event.details).to include('path' => path, 'mode' => SupportImpersonation::READ_ONLY_MODE,
                                         'method' => verb.to_s.upcase)
        expect(event.details['target']).to end_with("##{target.split('#').last}")
        expect(event.account).to eq(account)
        expect(event.operator).to eq(operator)

        swept += 1
      end

      expect(swept).to be >= 60
      expect(session_state['refused_count']).to eq(swept)
    end

    it 'cannot be driven to a success through the doors this rule does not own' do
      sign_in(operator)
      start!

      not_this_rule.each_key do |target|
        verb, path, = write_routes.find { |_v, _p, t| t == target }

        status =
          begin
            public_send(verb, path)
            response.status
          rescue AbstractController::ActionNotFound
            # A route with no action behind it: Rails answers before any
            # controller callback runs, and nothing could ever succeed.
            404
          end

        expect(status).not_to be_between(200, 299), "#{verb.upcase} #{path} (#{target}) answered #{status}"
      end
    end

    it 'leaves reading, the operator console and signing out open' do
      sign_in(operator)
      start!

      get root_path
      expect(response).to have_http_status(:ok)

      get templates_path
      expect(response).to have_http_status(:ok)

      get settings_account_path
      expect(response).to have_http_status(:ok)

      get operator_account_path(account)
      expect(response).to have_http_status(:ok)

      expect(events('impersonation.refused').count).to eq(0)
    end
  end

  # --- 4. edit mode ---------------------------------------------------------------

  describe 'edit mode' do
    let!(:template) { create(:template, account:, author: admin) }

    it 'lets a document be fixed' do
      sign_in(operator)
      start!(mode: SupportImpersonation::EDIT_MODE)

      put template_path(template), params: { template: { name: 'Onboarding (fixed by support)' } }

      expect(response).to have_http_status(:redirect).or have_http_status(:ok)
      expect(template.reload.name).to eq('Onboarding (fixed by support)')
      expect(events('impersonation.refused').count).to eq(0)
    end

    it 'still refuses money, people, credentials, configuration and signing' do
      webhook = create(:webhook_url, account:)
      member = create(:user, account:, role: User::EDITOR_ROLE)

      sign_in(operator)
      start!(mode: SupportImpersonation::EDIT_MODE)

      forbidden = {
        [:post, '/settings/billing/checkout'] => 'billing_settings#checkout',
        [:post, '/settings/billing/portal'] => 'billing_settings#portal',
        [:patch, '/settings/account'] => 'accounts#update',
        [:delete, '/settings/account'] => 'accounts#destroy',
        [:post, '/users'] => 'users#create',
        [:put, "/users/#{member.id}"] => 'users#update',
        [:post, "/users/#{member.id}/read_only"] => 'users_read_only#create',
        [:put, "/users/#{member.id}/send_reset_password"] => 'users_send_reset_password#update',
        [:post, '/account_invites'] => 'account_invites#create',
        [:patch, '/settings/profile/update_password'] => 'profile#update_password',
        [:patch, '/settings/profile/update_contact'] => 'profile#update_contact',
        [:post, '/mfa_setup'] => 'mfa_setup#create',
        [:delete, '/mfa_setup'] => 'mfa_setup#destroy',
        [:post, '/settings/api'] => 'api_settings#create',
        [:post, '/settings/reveal_access_token'] => 'reveal_access_token#create',
        [:post, '/account_configs'] => 'account_configs#create',
        [:post, '/settings/webhooks'] => 'webhook_settings#create',
        [:put, "/webhook_secret/#{webhook.id}"] => 'webhook_secret#update',
        [:post, '/testing_account'] => 'testing_accounts#create',
        [:patch, '/s/anything'] => 'submit_form#update',
        [:post, '/s/anything/decline'] => 'submit_form_decline#create',
        [:post, '/s/anything/invite'] => 'submit_form_invite#create',
        [:patch, '/d/anything'] => 'start_form#update'
      }

      forbidden.each do |(verb, path), target|
        public_send(verb, path, params: {})

        expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} answered #{response.status}"
        expect(last_event.details).to include('target' => target, 'mode' => SupportImpersonation::EDIT_MODE)
      end

      expect(account.reload.name).to eq('Northfield Legal')
      expect(member.reload.read_only_at).to be_nil
      expect(User.where(account:).count).to eq(2)
    end
  end

  # --- 5. the pages that print a credential ------------------------------------------

  describe 'secrets' do
    let!(:webhook) { create(:webhook_url, account:) }

    # The pages that print a credential, by path.
    let(:credential_pages) { ['/settings/reveal_access_token', '/settings/mcp', '/settings/email'] }

    # The API and MCP pages are paid rows: on the free plan they render an
    # upgrade call-to-action and print no token at all, which would prove
    # nothing.
    before { create(:account_subscription, account:, access_state: 'active', quantity: 1) }

    SupportImpersonation::MODES.each do |mode|
      it "refuses every credential page in #{mode} mode" do
        sign_in(operator)
        start!(mode:)

        credential_pages.each do |path|
          get path

          expect(response).to have_http_status(:forbidden), "GET #{path} answered #{response.status}"
          expect(last_event.action).to eq('impersonation.refused')
        end

        get "/webhook_secret/#{webhook.id}"
        expect(response).to have_http_status(:forbidden)
      end
    end

    it 'masks the API token on the settings page instead of offering to reveal it' do
      sign_in(operator)
      start!

      get settings_api_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-support-impersonation-masked-token')
      expect(response.body).not_to include(admin.access_token.token)
      expect(response.body).not_to include('access_token_container')
    end

    it 'shows the token normally when nobody is impersonating' do
      sign_in(admin)

      get settings_api_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('access_token_container')
      expect(response.body).not_to include('data-support-impersonation-masked-token')
    end
  end

  # --- 6. the ability layer (the belt) --------------------------------------------

  describe 'Ability' do
    it 'takes the same doors away one layer deeper, in both modes' do
      read_only = Ability.new(admin, support_impersonation: SupportImpersonation::READ_ONLY_MODE)
      edit = Ability.new(admin, support_impersonation: SupportImpersonation::EDIT_MODE)
      plain = Ability.new(admin)

      [read_only, edit].each do |ability|
        expect(ability.can?(:billing, account)).to be(false)
        expect(ability.can?(:administer, account)).to be(false)
        expect(ability.can?(:update, account)).to be(false)
        expect(ability.can?(:destroy, account)).to be(false)
        expect(ability.can?(:manage, admin)).to be(false)
        expect(ability.can?(:manage, admin.access_token)).to be(false)
        expect(ability.can?(:manage, McpToken.new(user: admin))).to be(false)
        expect(ability.can?(:manage, AccountInvite.new(account:))).to be(false)
        expect(ability.can?(:manage, AccountConfig.new(account:))).to be(false)
        expect(ability.can?(:manage, WebhookUrl.new(account:))).to be(false)
        expect(ability.can?(:manage, :mcp)).to be(false)

        # Looking is the whole point.
        expect(ability.can?(:read, account)).to be(true)
        expect(ability.can?(:read, admin)).to be(true)
        expect(ability.can?(:read, admin.access_token)).to be(true)
        expect(ability.can?(:read, Template.new(account:, author: admin))).to be(true)
      end

      # Documents: the one difference between the two modes.
      template = Template.new(account:, author: admin)
      expect(read_only.can?(:update, template)).to be(false)
      expect(edit.can?(:update, template)).to be(true)
      expect(plain.can?(:billing, account)).to be(true)
      expect(plain.can?(:manage, admin)).to be(true)
    end

    it 'keeps one list of what survives, so a later phase can add to it' do
      expect(Ability::KEPT_WHILE_IMPERSONATING).to eq(%i[read])
    end
  end

  # --- 7. the end ------------------------------------------------------------------

  describe 'ending' do
    it 'ends by hand, clears everything and records how long it lasted' do
      sign_in(operator)
      start!

      post '/account_configs' # one refusal, so the end row has something to count
      expect(response).to have_http_status(:forbidden)

      travel(4.minutes) do
        delete operator_current_impersonation_path
      end

      expect(response).to redirect_to(operator_account_path(account))
      expect(session_state).to be_nil
      expect(request.session[:impersonated_user_id]).to be_nil

      event = events('impersonation.end').first
      expect(event.account).to eq(account)
      expect(event.subject).to eq(admin)
      expect(event.details).to include('ended_by' => 'operator', 'refused_count' => 1,
                                       'start_event_id' => events('impersonation.start').first.id)
      expect(event.details['duration_seconds']).to be_between(200, 300)

      # And the doors are open again for the operator's own account.
      get operator_accounts_path
      expect(response).to have_http_status(:ok)
    end

    it 'refuses an end when there is nothing to end' do
      sign_in(operator)

      delete operator_current_impersonation_path

      expect(response).to redirect_to(operator_accounts_path)
      expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_not_active'))
    end

    it 'ends on sign-out, leaving no impersonation behind' do
      sign_in(operator)
      start!

      delete destroy_user_session_path

      expect(events('impersonation.end').first.details['ended_by']).to eq('sign_out')
      expect(request.session[SupportImpersonation::SESSION_KEY]).to be_nil
      expect(request.session[:impersonated_user_id]).to be_nil

      # Warden's test mode signs the operator straight back in on the next
      # request, which is exactly the point: what must not come back is the
      # impersonation.
      get root_path
      expect(response.body).not_to include('data-support-impersonation-banner')
    end

    it 'ends itself after an hour, wherever the operator has got to' do
      sign_in(operator)
      start!

      travel(SupportImpersonation::MAX_DURATION + 1.minute) do
        get templates_path

        expect(response).to redirect_to(operator_account_path(account))
        expect(flash[:notice]).to eq(I18n.t('support_impersonation_timed_out'))
      end

      expect(events('impersonation.end').first.details['ended_by']).to eq('timeout')
      expect(request.session[SupportImpersonation::SESSION_KEY]).to be_nil
      expect(request.session[:impersonated_user_id]).to be_nil
    end
  end

  # --- 8. what the customer sees ------------------------------------------------------

  describe 'the customer' do
    it 'sees every support session on their own account page, with the reason' do
      sign_in(operator)
      start!
      delete operator_current_impersonation_path
      delete destroy_user_session_path

      sign_in(admin)
      get settings_account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-support-access-card')
      expect(response.body).to include("data-support-access-row=\"#{events('impersonation.start').first.id}\"")
      expect(response.body).to include(ERB::Util.html_escape(reason))
      expect(response.body).to include(admin.email)
      expect(response.body).to include(I18n.t('support_impersonation_mode_read_only'))
      expect(response.body).not_to include('translation missing')
    end

    it 'shows nothing at all when support has never been in' do
      sign_in(admin)
      get settings_account_path

      expect(response.body).not_to include('data-support-access-card')
    end

    it 'is not shown the card to somebody who does not administer the account' do
      viewer = create(:user, :viewer, account:)

      sign_in(operator)
      start!
      delete operator_current_impersonation_path
      delete destroy_user_session_path

      sign_in(viewer)
      get settings_account_path

      expect(response.body).not_to include('data-support-access-card')
    end
  end

  # --- 9. one pass through a real browser -------------------------------------------

  # The door on the account page opens a dialog, the session starts, the bar is
  # actually on the page the operator lands on, and the way out on it works. The
  # request specs above prove what every door does; this proves an operator can
  # reach them at all.
  describe 'in a browser', type: :system do
    before { sign_in(operator) }

    it 'starts a session from the account page, shows the bar, and ends it again' do
      visit operator_account_path(account)

      click_button 'View as this user'

      within("#operator_impersonate_#{admin.id}") do
        fill_in 'reason', with: reason
        fill_in 'otp_attempt', with: operator.reload.current_otp
        click_button 'View as this user'
      end

      expect(page).to have_css('[data-support-impersonation-banner]')
      expect(page).to have_content('Support session')
      expect(page).to have_content('viewing Northfield Legal as jane@northfield.example')
      expect(page).to have_content('Read-only')
      expect(page).to have_content('Ticket 4182')
      expect(page).to have_no_content('translation missing')

      click_button 'End session'

      expect(page).to have_content('Support session ended.')
      expect(page).to have_no_css('[data-support-impersonation-banner]')
      expect(OperatorEvent.where(action: 'impersonation.end').count).to eq(1)
    end
  end
end
