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
      expect(events('impersonation.start')).to be_empty
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
      expect(events('impersonation.start')).to be_empty
    end

    it 'refuses a mode it does not know' do
      sign_in(operator)
      start!(mode: 'everything')

      expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_mode'))
      expect(events('impersonation.start')).to be_empty
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

      expect(events('impersonation.start')).to be_empty
    end

    it 'refuses a purged account' do
      account.update!(purged_at: Time.current)

      sign_in(operator)
      start!

      expect(flash[:alert]).to eq(I18n.t('operator_impersonation_refused_purged'))
      expect(events('impersonation.start')).to be_empty
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

  describe 'enforcement, swept off the route table' do
    # EVERY route in the application, with a placeholder standing in for each
    # id: the refusal happens before any controller looks at one, so what the
    # id points at is irrelevant. Every verb, not only the writes — a GET can
    # write (the signer's form) and a GET can print a credential (the webhook
    # HMAC page), which is the whole of review batch 2's first finding.
    def all_routes(verbs)
      Rails.application.routes.routes.filter_map do |route|
        controller = route.defaults[:controller].to_s

        next if controller.blank?

        verb = route.verb.to_s.split('|').find { |candidate| verbs.include?(candidate) }
        next if verb.nil?

        # A non-numeric placeholder on purpose: one route in this application
        # is constrained to a numeric id (`submitters_download`), and a digit
        # here would send the sweep to that route instead of the signer one it
        # means to test.
        path = route.path.spec.to_s.sub('(.:format)', '').gsub(/\*\w+/, 'x').gsub(/:[a-z_]+/, 'x')

        audit_path = route.path.spec.to_s.sub('(.:format)', '')
                          .gsub(/:(?:slug|token|signed_uuid|signed_key|signed_id|encoded_key)\b/, '[FILTERED]')
                          .gsub(/\*\w+/, 'x').gsub(/:[a-z_]+/, 'x')

        [verb.downcase.to_sym, path, "#{runtime_controller_path(controller)}##{route.defaults[:action]}", audit_path]
      end.uniq
    end

    # The rule is handed the controller's RUNTIME `controller_path`, and a
    # couple of those differ from the name in the route table
    # ('..._2fa...' becomes '...2fa...'). A classification keyed on the wrong
    # one would be documentation that does nothing.
    def runtime_controller_path(name)
      "#{name}_controller".camelize.constantize.controller_path
    rescue NameError
      name
    end

    def write_routes
      all_routes(%w[POST PUT PATCH DELETE]).reject { |_verb, _path, target| skip_in_sweep?(target) }
    end

    def read_routes
      all_routes(%w[GET])
    end

    def skip_in_sweep?(target)
      target.start_with?('operator/') || target == 'sessions#destroy' || not_this_rule.key?(target)
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
        'omniauth_callbacks#apple' => 'the same Devise gate',
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

    # The sweep is written off the route table and drops every route whose
    # `controller` is blank — right, because there is no controller to
    # classify, and also a blind spot: a Rack app mounted next month would
    # slip out of every example in this file with nobody noticing. So the
    # blind spot is a NAMED LIST and the list is asserted (review 8, proof
    # coverage).
    #
    # One entry today: Sidekiq::Web at /jobs. It is not an
    # ApplicationController, so it carries none of the impersonation guards —
    # which is safe only because the mount itself lives inside
    # `authenticated :user, ->(u) { u.operator_access? }` in config/routes.rb:
    # outside that constraint the route does not exist at all, so a customer
    # admin (and the support session riding on their account) meets a 404
    # rather than the job queue. Both halves are pinned here, so neither can
    # go quietly.
    let(:mounted_routes_without_a_controller) { ['/jobs'] }

    # The sweep above derives its set from the constant, so the promise it
    # makes shrinks with the constant: dropping `:export` from NEVER left it
    # green, and the export doors were then held only by CanCan a layer down
    # (checkpoint 10, E4). Written down here instead — the families the spec
    # says a support session never reaches, whatever anybody edits: money,
    # deleting the account, credentials, people and roles, the signer's own
    # doors, and bulk extraction of the customer's data.
    let(:forever_shut) do
      {
        # never, in either mode, for any verb (NEVER)
        'account_exports' => :export, 'submissions_export' => :export,
        'reveal_access_token' => :secret, 'mcp_settings' => :secret, 'webhook_secret' => :secret,
        'webhook_hmac' => :secret, 'email_smtp_settings' => :secret, 'testing_api_settings' => :secret,
        'start_form' => :signing, 'start_form_email2fa_send' => :signing, 'submit_form' => :signing,
        'submit_form_values' => :signing, 'submit_form_decline' => :signing,
        'submit_form_delegate' => :signing, 'submit_form_invite' => :signing,
        'submit_form_email2fas' => :signing, 'submit_form_download' => :signing,
        'submit_form_completed_download' => :signing, 'submit_form_document' => :signing,
        'submit_form_draw_signature' => :signing, 'submit_form_metadata' => :signing,
        'send_submission_email' => :signing, 'api/submitters' => :signing,
        'api/signing_sessions' => :signing, 'api/submitter_form_views' => :signing,
        'api/submitter_email_clicks' => :signing, 'api/attachments' => :signing,
        # writes refused in both modes; the page stays readable
        'billing_settings' => :forbidden, 'accounts' => :forbidden, 'users' => :forbidden,
        'users_read_only' => :forbidden, 'users_send_reset_password' => :forbidden,
        'account_invites' => :forbidden, 'invites' => :forbidden, 'invitations' => :forbidden,
        'passwords' => :forbidden, 'profile' => :forbidden, 'mfa_setup' => :forbidden,
        'api_settings' => :forbidden
      }
    end

    it 'sweeps every route but a named list of controller-less mounts' do
      mounted = Rails.application.routes.routes.filter_map do |route|
        next if route.defaults[:controller].to_s.present?

        route.path.spec.to_s.sub('(.:format)', '')
      end.uniq

      expect(mounted).to match_array(mounted_routes_without_a_controller)
    end

    it 'answers 404 on the controller-less mount for everybody but an enrolled operator' do
      mounted_routes_without_a_controller.each do |path|
        expect { get path }.to raise_error(ActionController::RoutingError), path

        sign_in(admin)
        expect { get path }.to raise_error(ActionController::RoutingError), path
        sign_out(admin)

        internal_admin = create(:user, :admin, account: create(:account, :internal))
        sign_in(internal_admin)
        expect { get path }.to raise_error(ActionController::RoutingError), path
        sign_out(internal_admin)
      end
    end

    # EVERY controller in the application has to be classified — GET-only ones
    # included (review batch 2) — so a new one of any shape fails here until
    # somebody has decided which side of the line it is on. The operator's own
    # console is excluded on purpose: `console?` keys on the path prefix, so a
    # console tab added later needs no entry.
    it 'classifies every controller in the application, whatever verbs it answers to' do
      controllers = all_routes(%w[GET POST PUT PATCH DELETE])
                    .map { |_verb, _path, target| target.split('#').first }
                    .uniq.reject { |name| SupportImpersonation.console?(name) }

      expect(controllers).to match_array(SupportImpersonation::CLASSIFICATION.keys)
    end

    # The `:secret` value in the table IS the list. They used to be two lists
    # and only one of them was enforced (review batch 2).
    it 'derives the credential-page list from the classification itself' do
      expect(SupportImpersonation::SECRET_CONTROLLERS)
        .to match_array(SupportImpersonation::CLASSIFICATION.select { |_, kind| kind == :secret }.keys)
      expect(SupportImpersonation::SECRET_CONTROLLERS).to include('webhook_hmac', 'webhook_secret',
                                                                  'reveal_access_token', 'mcp_settings',
                                                                  'email_smtp_settings')
    end

    # A GET is not automatically a read. Every door classified "never" is shut
    # for GET as well, and each refusal is audited.
    it 'refuses every read door classified never, and audits each one' do
      sign_in(operator)
      start!

      never = read_routes.select do |_verb, _path, target|
        SupportImpersonation::NEVER.include?(
          SupportImpersonation::CLASSIFICATION[target.split('#').first]
        )
      end

      expect(never.size).to be >= 15

      never.each do |verb, path, target|
        begin
          public_send(verb, path, as: :json)
        rescue StandardError => e
          raise "#{verb.upcase} #{path} (#{target}) raised #{e.class}: #{e.message}"
        end

        expect(response).to have_http_status(:forbidden),
                            "#{verb.upcase} #{path} (#{target}) answered #{response.status}"
        expect(last_event.action).to eq('impersonation.refused'), "#{target} was refused with no audit row"
      end
    end

    it 'pins the never-in-any-mode kinds and every door in the forbidden families, literally' do
      expect(SupportImpersonation::NEVER).to contain_exactly(:secret, :signing, :export)

      expect(SupportImpersonation::CLASSIFICATION.slice(*forever_shut.keys)).to eq(forever_shut)

      # And they are all still real controllers, so a rename cannot leave this
      # list pinning doors that no longer exist.
      expect(forever_shut.keys - SupportImpersonation::CLASSIFICATION.keys).to eq([])
    end

    # The export doors for real, in EDIT mode — the wider of the two — because
    # "never" has to mean the request is refused HERE and audited, not merely
    # refused by CanCan one layer down with nothing written about it.
    it 'refuses the account archive and the submissions CSV in edit mode, and audits both' do
      template = create(:template, account:, author: admin)

      sign_in(operator)
      start!(mode: SupportImpersonation::EDIT_MODE)

      ['/settings/export', "/templates/#{template.id}/submissions_export"].each do |path|
        expect { get path, as: :json }.to change { events('impersonation.refused').count }.by(1)

        expect(response).to have_http_status(:forbidden), "GET #{path} answered #{response.status}"
      end
    end

    # The refusal PAGE is asserted on its own below; this sweep asks for JSON
    # so that a hundred-odd requests do not each render a full layout. The
    # decision itself is format-blind — `SupportImpersonation.refuse?` never
    # looks at the format, only the branch that answers does.
    it 'refuses every write door, with an audit row for each' do
      sign_in(operator)
      start!

      swept = 0

      write_routes.each do |verb, path, target, audit_path|
        public_send(verb, path, as: :json)

        expect(response).to have_http_status(:forbidden),
                            "#{verb.upcase} #{path} (#{target}) answered #{response.status}"

        event = last_event
        expect(event.action).to eq('impersonation.refused'), "#{target} was refused with no audit row"
        expect(event.details).to include('path' => audit_path, 'mode' => SupportImpersonation::READ_ONLY_MODE,
                                         'method' => verb.to_s.upcase)
        expect(event.details['target']).to end_with("##{target.split('#').last}")
        expect(event.account).to eq(account)
        expect(event.operator).to eq(operator)

        swept += 1
      end

      expect(swept).to be >= 60
      expect(session_state['refused_count']).to eq(swept)
    end

    it 'answers a browser with the refusal page and an API client with JSON' do
      sign_in(operator)
      start!

      post '/account_configs'

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include('data-support-impersonation-refused')
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('support_impersonation_refused_body')))
      expect(response.body).to include('data-support-impersonation-banner')

      post '/account_configs', as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq('error' => I18n.t('support_impersonation_refused_json'))
    end

    it 'cannot be driven to a success through the doors this rule does not own' do
      sign_in(operator)
      start!

      not_this_rule.each_key do |target|
        verb, path, = all_routes(%w[POST PUT PATCH DELETE]).find { |_v, _p, t| t == target }

        # A raise is only ever an acceptable answer for the one route with no
        # action behind it. Anywhere else it would let a door excuse itself by
        # failing on the placeholder id instead of being tested (review batch
        # 2, N1), so it is a failure here.
        status =
          begin
            public_send(verb, path)
            response.status
          rescue StandardError => e
            expect(target).to eq('template_folders#destroy'), "#{verb.upcase} #{path} raised #{e.class}"
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

    # --- the same table, read again in EDIT mode (review 8, blocker 1) --------
    #
    # Before this, the only edit-mode proof in the suite was a hand-typed list
    # of 23 verb/path pairs, so a controller classified `:edit` that grew a
    # destructive action was covered by nothing at all — which is exactly how
    # edit mode came to be able to destroy a customer's signed documents and
    # complete a form on a signer's behalf. The sweep below derives its
    # expectations from CLASSIFICATION and EDIT_ACTION_OVERRIDES, so a new
    # write action on a document controller either lands in the allow-list —
    # with somebody having decided it is document work — or fails here.
    describe 'in edit mode' do
      def refused_in_edit?(target, payload = {})
        controller_path, action = target.split('#')

        SupportImpersonation.refuse?(controller_path:, action:, mode: SupportImpersonation::EDIT_MODE,
                                     read_request: false, params: payload)
      end

      # Everything an edit-mode session may write, by controller#action.
      let(:edit_allowed) do
        %w[
          templates#create templates#update templates#destroy
          templates_clone#create
          templates_clone_and_replace#create
          templates_detect_fields#create
          templates_folders#update
          templates_preferences#create templates_preferences#destroy
          templates_prefillable_fields#create
          templates_recipients#create
          templates_restore#create
          templates_share_link#create
          templates_uploads#create
          templates_versions#create
          template_documents#create
          template_folders#update
          submissions#create submissions#destroy
          submissions_resend_email#create
          submissions_unarchive#create
          submitters#update
          submitters_send_email#create
          api/templates#create api/templates#update api/templates#destroy
          api/templates_clone#create
          api/template_builder_sessions#create
          api/template_preview_sessions#create
          api/submissions#create api/submissions#destroy
        ]
      end

      it 'pins exactly the write doors edit mode may use' do
        derived = write_routes.map { |_verb, _path, target| target }.uniq.reject { |target| refused_in_edit?(target) }

        expect(derived).to match_array(edit_allowed)
      end

      # Two of the doors above do a reversible thing and an irreversible one
      # behind the same action, and two more sign for somebody if the payload
      # says so. The override table is what tells them apart, and every entry
      # in it has to name an action of a controller that was classified as
      # document work in the first place.
      it 'pins the per-action overrides, and each one belongs to a document controller' do
        expect(SupportImpersonation::EDIT_ACTION_OVERRIDES).to eq(
          'templates#destroy' => :permanent_destroy,
          'submissions#destroy' => :permanent_destroy,
          'api/templates#destroy' => :permanent_destroy,
          'api/submissions#destroy' => :permanent_destroy,
          'submissions#create' => :completion,
          'api/submissions#create' => :completion,
          'submitters_resubmit#update' => :never
        )

        SupportImpersonation::EDIT_ACTION_OVERRIDES.each_key do |target|
          kind = SupportImpersonation::CLASSIFICATION[target.split('#').first]

          expect(kind).to eq(:edit), "#{target} is not on a controller classified as document work"
          expect(edit_allowed).not_to include(target) if refused_in_edit?(target)
        end

        # And they really are payload-sensitive rather than door-wide: the
        # archive branch and a creation nobody has marked completed stay open.
        expect(refused_in_edit?('templates#destroy', 'permanently' => 'true')).to be(true)
        expect(refused_in_edit?('templates#destroy')).to be(false)
        expect(refused_in_edit?('api/submissions#create',
                                'submitters' => [{ 'email' => 'a@b.test', 'completed' => true }])).to be(true)
        expect(refused_in_edit?('api/submissions#create', 'submitters' => [{ 'email' => 'a@b.test' }])).to be(false)
      end

      # The completion question, at the level of the rule itself. The guard has
      # to ask what the BUILDER asks — `attrs[:completed].present?` — and it
      # has to ask it only of submitter-shaped nodes (review 8, V2-1 and V2-3).
      it 'asks the builder’s own question about completion, and only about the submitter' do
        expect(SupportImpersonation::COMPLETION_KEYS).to eq(%w[completed completed_at])
        expect(SupportImpersonation::CUSTOMER_DATA_KEYS)
          .to eq(%w[values metadata variables fields preferences])

        completing = lambda do |value|
          refused_in_edit?('api/submissions#create',
                           'submitters' => [{ 'email' => 'a@b.test', 'completed' => value }])
        end

        # Anything the builder would treat as "finished" is refused, whatever
        # it spells — `.present?` is true for every one of these.
        ['false', 'no', '0', 0, 'x', 2, true, 'true', '1', 1, 'FALSE'].each do |value|
          expect(completing.call(value)).to be(true), "completed: #{value.inspect} was not refused"
        end

        # And nothing the builder would treat as "not finished" is refused —
        # the guard is neither tighter nor looser than the door it guards.
        [nil, false, '', ' ', [], {}].each do |value|
          expect(completing.call(value)).to be(false), "completed: #{value.inspect} was refused for nothing"
        end

        # `completed_at` reaches no builder today; it is closed in advance.
        expect(refused_in_edit?('api/submissions#create',
                                'submitters' => [{ 'completed_at' => '2026-01-01' }])).to be(true)

        # The customer's own data is never mistaken for the control: a field,
        # a variable or a preference called "completed" is not a signature.
        SupportImpersonation::CUSTOMER_DATA_KEYS.each do |key|
          expect(refused_in_edit?('api/submissions#create',
                                  'submitters' => [{ 'email' => 'a@b.test', key => { 'completed' => true } }]))
            .to be(false), "a customer field under #{key}: was mistaken for a completion"
        end
      end

      it 'refuses every write door that is not document work, with an audit row for each' do
        sign_in(operator)
        start!(mode: SupportImpersonation::EDIT_MODE)

        swept = 0

        write_routes.each do |verb, path, target, audit_path|
          next unless refused_in_edit?(target)

          public_send(verb, path, as: :json)

          expect(response).to have_http_status(:forbidden),
                              "#{verb.upcase} #{path} (#{target}) answered #{response.status} in edit mode"

          event = last_event
          expect(event.action).to eq('impersonation.refused'), "#{target} was refused with no audit row"
          expect(event.details).to include('path' => audit_path, 'mode' => SupportImpersonation::EDIT_MODE,
                                           'method' => verb.to_s.upcase)
          expect(event.account).to eq(account)

          swept += 1
        end

        expect(swept).to be >= 40
        expect(session_state['refused_count']).to eq(swept)
        expect(events('impersonation.action')).to be_empty
      end
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
        public_send(verb, path, params: {}, as: :json)

        expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} answered #{response.status}"
        expect(last_event.details).to include('target' => target, 'mode' => SupportImpersonation::EDIT_MODE)
      end

      expect(account.reload.name).to eq('Northfield Legal')
      expect(member.reload.read_only_at).to be_nil
      expect(User.where(account:).count).to eq(2)
    end
  end

  # --- 4b. edit mode never destroys and never signs (review 8, blocker 1) -------------
  #
  # "Allow document edits" used to mean any write on a document controller, so
  # an operator could permanently destroy a customer's completed submission —
  # its submitters and its whole `submission_events` trail with it — and could
  # create a submitter already marked `completed: true`, which is signing for
  # somebody. Neither left a refusal, and neither left an audit row: the end
  # row said `refused_count: 0` and the customer's Support-access card said the
  # session was clean.
  #
  # These are the review's own probes, executed. The rule is: nothing a support
  # session does is irreversible, and no submitter reaches `completed` through
  # one. Archiving — a soft delete the customer can undo — stays, because that
  # is the work edit mode exists to do, and now leaves a row saying so.
  describe 'edit mode: what it may never do, and what it now records' do
    let!(:template) { create(:template, account:, author: admin) }
    let(:submission) do
      create(:submission, :with_submitters, template:, created_by_user: admin, account_id: account.id)
    end
    let(:signed_submission) do
      create(:submission, :with_submitters, :with_events, template:, created_by_user: admin, account_id: account.id)
    end

    def start_edit!
      sign_in(operator)
      start!(mode: SupportImpersonation::EDIT_MODE)
    end

    def expect_refused!(target)
      expect(response).to have_http_status(:forbidden)
      expect(last_event.action).to eq('impersonation.refused')
      expect(last_event.details).to include('target' => target, 'mode' => SupportImpersonation::EDIT_MODE)
      expect(events('impersonation.action')).to be_empty
    end

    it 'refuses a permanent template destroy, and the template is still there' do
      start_edit!

      delete template_path(template), params: { permanently: 'true' }

      expect_refused!('templates#destroy')
      expect(Template.exists?(template.id)).to be(true)
      expect(template.reload.archived_at).to be_nil
    end

    it 'refuses a permanent submission destroy, and the signing evidence survives it' do
      submitters = signed_submission.submitters.count
      trail = SubmissionEvent.where(submission_id: signed_submission.id).count

      expect(submitters).to be_positive
      expect(trail).to be_positive

      start_edit!

      delete submission_path(signed_submission), params: { permanently: 'true' }

      expect_refused!('submissions#destroy')
      expect(Submission.exists?(signed_submission.id)).to be(true)
      expect(Submitter.where(submission_id: signed_submission.id).count).to eq(submitters)
      expect(SubmissionEvent.where(submission_id: signed_submission.id).count).to eq(trail)
    end

    it 'refuses the same two doors on the browser-session API' do
      start_edit!

      delete "/api/templates/#{template.id}?permanently=true"

      expect_refused!('api/templates#destroy')
      expect(Template.exists?(template.id)).to be(true)

      delete "/api/submissions/#{submission.id}?permanently=true"

      expect(response).to have_http_status(:forbidden)
      expect(last_event.details).to include('target' => 'api/submissions#destroy')
      expect(Submission.exists?(submission.id)).to be(true)
      expect(submission.reload.archived_at).to be_nil
    end

    it 'refuses an API submission that arrives already completed, and creates nobody' do
      start_edit!

      expect do
        post '/api/submissions',
             params: { template_id: template.id, send_email: false,
                       submitters: [{ email: 'signer@example.test', completed: true,
                                      role: template.submitters.first['name'] }] }.to_json,
             headers: { 'CONTENT_TYPE' => 'application/json' }
      end.not_to(change { Submission.where(account_id: account.id).count })

      expect_refused!('api/submissions#create')
      expect(Submitter.where(account_id: account.id).where.not(completed_at: nil)).to be_empty
    end

    it 'still creates one through the same door when nobody is marked completed' do
      start_edit!

      expect do
        post '/api/submissions',
             params: { template_id: template.id, send_email: false,
                       submitters: [{ email: 'signer@example.test',
                                      role: template.submitters.first['name'] }] }.to_json,
             headers: { 'CONTENT_TYPE' => 'application/json' }
      end.to change { Submission.where(account_id: account.id).count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(Submitter.where(account_id: account.id).where.not(completed_at: nil)).to be_empty
      expect(events('impersonation.refused')).to be_empty
      expect(events('impersonation.action').first.details).to include('target' => 'api/submissions#create')
    end

    # V2-1/X1. The guard used to test membership of a four-element list while
    # the builder tests `.present?`, so one character got round it: a support
    # session could post `completed: "false"` and a document appeared in the
    # customer's account showing their CEO had signed it. Every spelling the
    # verifier drove through that door, executed here.
    it 'refuses every spelling of completed the document builder would honour' do
      start_edit!

      ['false', 'no', '0', 0, 'x', 2].each_with_index do |value, index|
        refused = events('impersonation.refused').count

        expect do
          post '/api/submissions',
               params: { template_id: template.id, send_email: false,
                         submitters: [{ email: "signer-#{index}@example.test", completed: value,
                                        role: template.submitters.first['name'] }] }.to_json,
               headers: { 'CONTENT_TYPE' => 'application/json' }
        end.not_to(change { Submission.where(account_id: account.id).count })

        expect(response).to have_http_status(:forbidden),
                            "completed: #{value.inspect} answered #{response.status}"
        expect(events('impersonation.refused').count)
          .to eq(refused + 1), "completed: #{value.inspect} left no refusal row"
        expect(last_event.details).to include('target' => 'api/submissions#create',
                                              'mode' => SupportImpersonation::EDIT_MODE)
        expect(Submitter.where(account_id: account.id).where.not(completed_at: nil)).to be_empty
      end

      expect(events('impersonation.action')).to be_empty
    end

    # V2-3/X3, the other direction. The scan was depth-blind, so a customer
    # whose own template carries a checkbox called "completed" — a compliance
    # form's "Training completed?" — could not be helped in edit mode at all,
    # and every attempt wrote a refusal onto their own Support-access card.
    it 'lets a customer’s own field called “completed” through, and completes nobody' do
      fields = template.fields.deep_dup
      field = fields.find { |candidate| candidate['type'] == 'checkbox' }

      expect(field).to be_present

      field['name'] = 'completed'
      template.update!(fields:)

      start_edit!

      expect do
        post '/api/submissions',
             params: { template_id: template.id, send_email: false,
                       submitters: [{ email: 'signer@example.test', role: template.submitters.first['name'],
                                      values: { 'completed' => true } }] }.to_json,
             headers: { 'CONTENT_TYPE' => 'application/json' }
      end.to change { Submission.where(account_id: account.id).count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(events('impersonation.refused')).to be_empty

      submitter = Submitter.where(account_id: account.id).order(:id).last
      expect(submitter.completed_at).to be_nil
      expect(submitter.values[field['uuid']]).to be_truthy

      expect(events('impersonation.action').count).to eq(1)
      expect(events('impersonation.action').first.details)
        .to include('target' => 'api/submissions#create', 'outcome' => SupportImpersonation::ACTION_CHANGED)
    end

    # X4. The row used to be written BEFORE the action ran, so a request that
    # changed nothing still told the customer "1 change". It is written after
    # the action now and says which of the two it was.
    it 'records an allowed request that failed as an attempt, and never as a change' do
      start_edit!

      expect do
        post template_documents_path(template), params: {}, as: :json
      end.to change { events('impersonation.action').count }.by(1)

      expect(response).to have_http_status(422)
      expect(template.reload.schema_documents.count).to eq(1)

      event = events('impersonation.action').first
      expect(event.details).to include('target' => 'template_documents#create',
                                       'outcome' => SupportImpersonation::ACTION_FAILED)
      expect(events('impersonation.refused')).to be_empty

      delete operator_current_impersonation_path

      expect(events('impersonation.end').first.details).to include('action_count' => 0, 'refused_count' => 0)
    end

    # W1/Y1. The row used to be an `after_action`, and an exception skips the
    # after callbacks — so a 422 the API's own `rescue_from` answered left the
    # customer's log with NOTHING, while the identical 422 the controller
    # rendered itself (the example above) left a `failed` row. Two outcomes for
    # one kind of failure is not an audit. The writer wraps the whole request
    # now, error handling included.
    it 'writes the row for a 4xx an error handler answered, not only for one the controller rendered' do
      start_edit!

      # `rescue_from Params::BaseValidator::InvalidParameterError` — a submitter
      # with no email, phone or name at all.
      expect do
        post '/api/submissions',
             params: { template_id: template.id, submitters: [{}] }.to_json,
             headers: { 'CONTENT_TYPE' => 'application/json' }
      end.not_to(change { Submission.where(account_id: account.id).count })

      expect(response).to have_http_status(422)

      # `rescue_from JSON::ParserError` — a body Rails cannot even parse, which
      # used to take the rule itself down before it had classified the request.
      post '/api/submissions', params: '{"template_id":', headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(422)

      rows = events('impersonation.action').reorder(:id)

      expect(rows.count).to eq(2)
      expect(rows.map { |row| row.details.values_at('target', 'outcome') })
        .to eq([['api/submissions#create', SupportImpersonation::ACTION_FAILED],
                ['api/submissions#create', SupportImpersonation::ACTION_FAILED]])
      expect(events('impersonation.refused')).to be_empty

      delete operator_current_impersonation_path

      expect(events('impersonation.end').first.details).to include('action_count' => 0)
    end

    # Y3. Half of this application says no by redirecting BACK with an alert,
    # not with a 4xx: a signer on a document somebody has already opened, a
    # form with nothing in it. Counting those as changes told the customer
    # support had edited something it had not. The second half of the example
    # is the trap that makes the rule hard: the alert from the refused request
    # is still sitting in the flash when the next one arrives, and a real
    # change must not inherit it.
    it 'records a redirect that refused the change as an attempt, and the next real change as a change' do
      submitter = submission.submitters.first
      original = submitter.email

      start_edit!

      put submitter_path(submitter), params: { submitter: { email: '', name: '', phone: '' } }

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('at_least_one_field_must_be_filled'))
      expect(submitter.reload.email).to eq(original)

      put submitter_path(submitter), params: { submitter: { email: 'fixed@example.test' } }

      expect(response).to have_http_status(:redirect)
      expect(submitter.reload.email).to eq('fixed@example.test')

      rows = events('impersonation.action').reorder(:id)

      expect(rows.map { |row| row.details['outcome'] })
        .to eq([SupportImpersonation::ACTION_FAILED, SupportImpersonation::ACTION_CHANGED])
      expect(rows.map { |row| row.details['target'] }).to all(eq('submitters#update'))
      expect(events('impersonation.refused')).to be_empty

      delete operator_current_impersonation_path

      expect(events('impersonation.end').first.details).to include('action_count' => 1)
    end

    # Y1's other half: the change is COMMITTED and then something further down
    # the action raises. The old writer never ran, so the one request in the
    # session that genuinely broke something was the one the customer's log did
    # not mention. It gets a row saying `error`, and the exception carries on
    # untouched to whoever owns the 500.
    it 'records a request that raised after the change was committed, and re-raises it' do
      submitter = submission.submitters.first

      allow(SearchEntries).to receive(:enqueue_reindex).and_raise(RuntimeError, 'the search index is down')

      start_edit!

      expect do
        put submitter_path(submitter), params: { submitter: { email: 'fixed@example.test' } }
      end.to raise_error(RuntimeError, /search index/)

      expect(submitter.reload.email).to eq('fixed@example.test')

      rows = events('impersonation.action')

      expect(rows.count).to eq(1)
      expect(rows.first.details).to include('target' => 'submitters#update',
                                            'outcome' => SupportImpersonation::ACTION_ERROR)
      expect(rows.first.details['records']).to include('id' => submitter.id.to_s)
      expect(events('impersonation.refused')).to be_empty
    end

    # The whole rule in one session, one request per ending, and the number the
    # customer is shown at the end of it. Five allowed requests, five rows, and
    # only the two that actually did something counted.
    it 'leaves exactly one row per request however the request ends, and counts only the ones that landed' do
      submitter = submission.submitters.first

      start_edit!

      # 200: an API create that works.
      post '/api/submissions',
           params: { template_id: template.id, send_email: false,
                     submitters: [{ email: 'signer@example.test', role: template.submitters.first['name'] }] }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)

      # 302 with no alert: a real change through a browser door.
      put submitter_path(submitter), params: { submitter: { email: 'fixed@example.test' } }

      # 302 with an alert: the door was open, the account turned it away.
      put submitter_path(submitter), params: { submitter: { email: '', name: '', phone: '' } }

      # 422 the controller renders itself.
      post template_documents_path(template), params: {}, as: :json

      # 422 a `rescue_from` renders.
      post '/api/submissions', params: { template_id: template.id, submitters: [{}] }.to_json,
                               headers: { 'CONTENT_TYPE' => 'application/json' }

      rows = events('impersonation.action').reorder(:id)

      expect(rows.map { |row| row.details.values_at('target', 'outcome') })
        .to eq([['api/submissions#create', SupportImpersonation::ACTION_CHANGED],
                ['submitters#update', SupportImpersonation::ACTION_CHANGED],
                ['submitters#update', SupportImpersonation::ACTION_FAILED],
                ['template_documents#create', SupportImpersonation::ACTION_FAILED],
                ['api/submissions#create', SupportImpersonation::ACTION_FAILED]])
      expect(events('impersonation.refused')).to be_empty

      delete operator_current_impersonation_path

      expect(events('impersonation.end').first.details)
        .to include('action_count' => 2, 'refused_count' => 0)
    end

    # The other half of "exactly one row per request": a write the request
    # rule allows but the ability layer refuses leaves the refusal row and
    # nothing else. Never a refusal AND a change for the same request.
    it 'writes no action row when the ability layer is the one that refuses' do
      elsewhere = create(:account, name: 'Somebody Else')
      stranger = create(:template, account: elsewhere, author: create(:user, :admin, account: elsewhere))

      start_edit!

      put template_path(stranger), params: { template: { name: 'Renamed by support' } }

      expect(stranger.reload.name).not_to eq('Renamed by support')
      expect(events('impersonation.refused').count).to eq(1)
      expect(events('impersonation.refused').first.details)
        .to include('target' => 'templates#update', 'refused_by' => 'ability')
      expect(events('impersonation.action')).to be_empty
    end

    # B3 (review 8). The row was written; the COUNTER was not — so a session
    # the ability layer turned away five times reported "1 blocked" on the way
    # out, and the customer's Support-access card printed that number. The
    # count the customer is shown has to be the count of rows in their own log.
    it 'counts an ability-layer refusal towards the total the customer is shown' do
      elsewhere = create(:account, name: 'Somebody Else')
      stranger = create(:template, account: elsewhere, author: create(:user, :admin, account: elsewhere))

      start_edit!

      2.times { put template_path(stranger), params: { template: { name: 'Renamed by support' } } }
      delete template_path(template), params: { permanently: 'true' } # refused by the request rule

      expect(session_state['refused_count']).to eq(3)

      delete operator_current_impersonation_path

      expect(events('impersonation.refused').count).to eq(3)
      expect(events('impersonation.end').first.details).to include('refused_count' => 3, 'action_count' => 0)
    end

    # V2-4. `records` says WHICH record was touched and nothing else: an
    # id-shaped KEY carrying the customer's free text (an `external_id`, an
    # application key) is customer data, and these rows outlive the records
    # they name.
    it 'names only id-shaped values in the row it writes' do
      submitter = submission.submitters.first
      folder_uuid = SecureRandom.uuid

      start_edit!

      put submitter_path(submitter), params: { submitter: { email: 'changed@example.test' },
                                               folder_id: folder_uuid,
                                               external_id: 'ACME — purchase order 7 (renewal)' }

      event = events('impersonation.action').first
      expect(event.details['records']).to eq('id' => submitter.id.to_s, 'folder_id' => folder_uuid)
      expect(event.details.to_json).not_to include('ACME')
    end

    it 'refuses the signer form and the resubmit door, and nobody is completed' do
      submitter = submission.submitters.first
      submitter.update!(email: admin.email)

      start_edit!

      put "/s/#{submitter.slug}", params: { submitter: { completed: true } }, as: :json

      expect_refused!('submit_form#update')
      expect(submitter.reload.completed_at).to be_nil

      expect { put submitters_resubmit_path(submitter) }.not_to change(Submission, :count)

      expect(response).to have_http_status(:forbidden)
      expect(last_event.details).to include('target' => 'submitters_resubmit#update')
    end

    it 'lets support fix a signer’s email address, and writes one row saying so' do
      submitter = submission.submitters.first

      start_edit!

      expect do
        put submitter_path(submitter), params: { submitter: { email: 'changed@example.test' } }
      end.to change { events('impersonation.action').count }.by(1)

      expect(submitter.reload.email).to eq('changed@example.test')

      event = events('impersonation.action').first
      expect(event.details).to include('target' => 'submitters#update', 'mode' => SupportImpersonation::EDIT_MODE,
                                       'method' => 'PUT', 'path' => submitter_path(submitter),
                                       'outcome' => SupportImpersonation::ACTION_CHANGED)
      expect(event.details['records']).to include('id' => submitter.id.to_s)
      expect(event.account).to eq(account)
      expect(event.subject).to eq(admin)
      expect(event.operator).to eq(operator)
      expect(event.reason).to eq(reason)
      expect(events('impersonation.refused')).to be_empty
    end

    it 'lets support archive — the reversible half of the same doors — and records each one' do
      start_edit!

      expect { delete template_path(template) }.to change { events('impersonation.action').count }.by(1)

      expect(template.reload.archived_at).to be_present
      expect(events('impersonation.action').first.details).to include('target' => 'templates#destroy')

      expect { delete "/api/submissions/#{submission.id}" }.to change { events('impersonation.action').count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(submission.reload.archived_at).to be_present
      expect(events('impersonation.refused')).to be_empty
    end

    it 'reports what the session changed and what it was stopped from doing, on the way out' do
      start_edit!

      delete template_path(template)                                  # allowed: a reversible archive
      delete template_path(template), params: { permanently: 'true' } # refused: irreversible
      post '/account_configs'                                         # refused: not document work

      delete operator_current_impersonation_path

      expect(events('impersonation.action').count).to eq(1)
      expect(events('impersonation.refused').count).to eq(2)
      expect(events('impersonation.end').first.details)
        .to include('mode' => SupportImpersonation::EDIT_MODE, 'refused_count' => 2, 'action_count' => 1)

      # Ending the session is the console's own door and is not a change to
      # the customer's account, so it adds no action row of its own.
      expect(Template.exists?(template.id)).to be(true)
    end

    it 'tells the customer on their own page how much the session changed' do
      start_edit!

      delete template_path(template)
      delete template_path(template), params: { permanently: 'true' }
      delete operator_current_impersonation_path
      delete destroy_user_session_path

      sign_in(admin)
      get settings_account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-support-access-card')
      expect(response.body).to include("data-support-access-changes=\"#{events('impersonation.start').first.id}\"")
      expect(response.body).to include(I18n.t('support_access_changes'))
      expect(response.body).to include(I18n.t('support_access_changes_summary', count: 1))
      expect(response.body).to include(I18n.t('support_access_blocked_summary', count: 1))
      expect(response.body).not_to include('translation missing')
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
        expect(flash[:notice]).to eq(I18n.t('support_impersonation_ended_timeout'))
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
      # A read-only session changed nothing, and the card says so in words
      # rather than leaving the customer to assume it.
      expect(response.body).to include(I18n.t('support_access_changes_summary', count: 0))
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

  # --- 8b. review batch 2 regressions --------------------------------------------

  describe 'the doors review batch 2 found open' do
    let!(:template) { create(:template, account:, author: admin) }
    let!(:webhook) { create(:webhook_url, account:) }

    # H1 / #4. `/api/*` is ActionController::API and accepts the browser
    # session, so before the fix a read-only session could drive every one of
    # these with no rule, no ability layer and no expiry.
    SupportImpersonation::MODES.each do |mode|
      it "runs the same rule on the browser-session API in #{mode} mode" do
        submission = create(:submission, :with_submitters, template:, created_by_user: admin)
        submitter = submission.submitters.first

        sign_in(operator)
        start!(mode:)

        # The "sign as the person" door: `completed: true` on a submitter.
        patch "/api/submitters/#{submitter.id}", params: { completed: true }.to_json,
                                                 headers: { 'CONTENT_TYPE' => 'application/json' }

        expect(response).to have_http_status(:forbidden)
        expect(last_event.action).to eq('impersonation.refused')
        expect(last_event.details['target']).to eq('api/submitters#update')
        expect(submitter.reload.completed_at).to be_nil

        # Reading one is fine; the signing family is shut for every verb.
        get "/api/submitters/#{submitter.id}"
        expect(response).to have_http_status(:forbidden)

        # A document write. Edit mode has to WORK here — the in-app builder
        # saves through this door, so a mode the console offers and the API
        # refuses is a mode that does not exist (review batch 2, N2) — and
        # read-only has to refuse it with exactly one row, not one per ability
        # check.
        before = events('impersonation.refused').count

        patch "/api/templates/#{template.id}", params: { name: "Renamed in #{mode}" }.to_json,
                                               headers: { 'CONTENT_TYPE' => 'application/json' }

        if mode == SupportImpersonation::EDIT_MODE
          expect(response).to have_http_status(:ok)
          expect(template.reload.name).to eq('Renamed in edit')
          expect(events('impersonation.refused').count).to eq(before)
        else
          expect(response).to have_http_status(:forbidden)
          expect(last_event.details['target']).to eq('api/templates#update')
          expect(events('impersonation.refused').count).to eq(before + 1)
          expect(template.reload.name).not_to eq('Renamed in read_only')
        end
      end
    end

    # ... and it acts as the PERSON the session says it is viewing as, not as
    # the operator (which is what made edit mode inert here).
    it 'acts as the impersonated person on the browser-session API' do
      sign_in(operator)
      start!

      get '/api/user'

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['email']).to eq(admin.email)
    end

    # ... and a real token client is a different client: no session, no rule.
    it 'leaves token-authenticated API traffic alone' do
      create(:account_subscription, account:, access_state: 'active', quantity: 1)

      sign_in(operator)
      start!

      # A token client is a different client: its own cookie jar, holding no
      # session at all, which is the only thing this rule ever looks at.
      Warden.test_reset!
      token_client = open_session

      token_client.patch("/api/templates/#{template.id}",
                         params: { name: 'Renamed by the token' }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json',
                                    'X-Auth-Token' => admin.access_token.token })

      expect(token_client.response).to have_http_status(:ok)
      expect(template.reload.name).to eq('Renamed by the token')
      expect(events('impersonation.refused')).to be_empty
      expect(events('impersonation.end')).to be_empty
    end

    # N1. The signer's upload door has its own ActionController::API base, no
    # Devise and no Pretender — but it honours the session cookie and is keyed
    # on a slug the operator can read off the customer's submission page, so a
    # read-only session could attach a signature image to a live submitter.
    it 'refuses the signer upload door, with a real submitter, and attaches nothing' do
      submission = create(:submission, :with_submitters, template:, created_by_user: admin)
      submitter = submission.submitters.first

      sign_in(operator)
      start!

      expect do
        post '/api/attachments',
             params: { submitter_slug: submitter.slug, type: 'attachments',
                       file: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-document.pdf'),
                                                          'application/pdf') }
      end.not_to(change { submitter.reload.attachments.count })

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq('error' => I18n.t('support_impersonation_refused_json'))

      event = last_event
      expect(event.action).to eq('impersonation.refused')
      expect(event.details['target']).to eq('api/attachments#create')
      expect(event.operator).to eq(operator)
      expect(event.account).to eq(account)
    end

    # H2. The HMAC page printed the whole decrypted signing secret on a GET.
    it 'refuses the webhook HMAC page and never prints the secret' do
      secret = webhook.hmac_secret
      expect(secret).to be_present

      sign_in(operator)
      start!

      get "/webhook_hmac/#{webhook.id}"

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(secret)
      expect(last_event.details['target']).to eq('webhook_hmac#show')
    end

    # H3 / #1. `GET /s/:slug` is not a read: it saves default values and
    # attaches the impersonated person's own signature to a live submitter.
    it 'refuses the signer form on a GET, and writes nothing to the submitter' do
      submission = create(:submission, :with_submitters, template:, created_by_user: admin)
      submitter = submission.submitters.first
      submitter.update!(email: admin.email)

      sign_in(operator)
      start!

      expect { get "/s/#{submitter.slug}" }.not_to(change { submitter.reload.attachments.count })

      expect(response).to have_http_status(:forbidden)
      expect(submitter.reload.opened_at).to be_nil
      expect(last_event.details['target']).to eq('submit_form#show')

      # The page's own telemetry door is shut for the same reason.
      post '/api/submitter_form_views', params: { submitter_slug: submitter.slug }.to_json,
                                        headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:forbidden)
      expect(submitter.reload.opened_at).to be_nil
    end

    # H4 / #5. The binding is re-asked on every request.
    it 'ends the session the moment the operator loses platform access' do
      sign_in(operator)
      start!

      operator.update!(platform_operator: false)

      get templates_path

      # NOT the console: they can no longer open it, and a redirect there is a
      # redirect to a 404 (review batch 2, N3).
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq(I18n.t('support_impersonation_ended_operator_access_lost'))
      expect(events('impersonation.end').first.details['ended_by']).to eq('operator_access_lost')
      expect(request.session[SupportImpersonation::SESSION_KEY]).to be_nil
      expect(request.session[:impersonated_user_id]).to be_nil
    end

    it 'ends the session when the person is archived mid-session' do
      sign_in(operator)
      start!

      admin.update!(archived_at: Time.current)

      get root_path

      expect(response).to redirect_to(operator_account_path(account))
      expect(events('impersonation.end').first.details['ended_by']).to eq('rebinding')
      expect(request.session[SupportImpersonation::SESSION_KEY]).to be_nil
    end

    it 'never follows the person into another account' do
      other = create(:account, name: 'Southgate Partners')
      create(:user, :admin, account: other)

      sign_in(operator)
      start!

      Accounts::MoveUser.call(user: admin, to: other)

      get root_path

      expect(response).to redirect_to(operator_account_path(account))
      expect(events('impersonation.end').first.details['ended_by']).to eq('rebinding')
      expect(request.session[SupportImpersonation::SESSION_KEY]).to be_nil
      expect(request.session[:impersonated_user_id]).to be_nil
    end

    # M13. Sign-out after the hour is up must still sign out.
    it 'still signs the operator out when the session expired first' do
      sign_in(operator)
      start!

      travel(SupportImpersonation::MAX_DURATION + 1.minute) do
        delete destroy_user_session_path

        expect(response).to have_http_status(:redirect)
      end

      expect(events('impersonation.end').first.details['ended_by']).to eq('timeout')
      expect(request.session[SupportImpersonation::SESSION_KEY]).to be_nil
      expect(request.session[:impersonated_user_id]).to be_nil

      # Warden's test login puts the operator back on the next request; what
      # must not come back is the impersonation.
      get root_path
      expect(response.body).not_to include('data-support-impersonation-banner')
    end

    # M9. A refused START used to leave no trace at all.
    it 'audits a refused start, without ever recording the code' do
      sign_in(operator)
      start!(code: '000000')

      event = events('impersonation.refused').first
      expect(event).to be_present
      expect(event.account).to eq(account)
      expect(event.operator).to eq(operator)
      expect(event.reason).to eq(reason)
      expect(event.details).to include('target' => 'operator/impersonations#create',
                                       'refusal' => I18n.t('operator_impersonation_refused_code'))
      expect(event.details.to_json).not_to include('000000')
      expect(events('impersonation.start')).to be_empty
    end

    # M9, second half: a door shut by the ability layer rather than by the
    # request rule is still a locked door the customer hears about.
    it 'audits a refusal that only the ability layer made' do
      sign_in(operator)
      start!

      get settings_users_path

      expect(response).to redirect_to(root_path)
      expect(events('impersonation.refused').first.details).to include('refused_by' => 'ability')
    end

    # L6. Not even the first five characters.
    it 'prints none of the API token at all' do
      create(:account_subscription, account:, access_state: 'active', quantity: 1)

      sign_in(operator)
      start!

      get settings_api_index_path

      token = admin.access_token.token
      expect(response.body).to include('data-support-impersonation-masked-token')
      expect(response.body).not_to include(token[0, 5])
    end
  end

  # --- 8b. the session that was walked away from (Session 8, walk finding 2) ---------
  #
  # Every other ending is written by the operator's NEXT request. Somebody who
  # closes the browser never makes one: the session was over on the clock, but
  # the customer's Support-access card said "In progress" for ever and their
  # log had a start with no ending. The hourly tidy-up writes it.
  describe 'a session the operator walked away from' do
    def abandon!
      sign_in(operator)
      start!(mode: SupportImpersonation::EDIT_MODE)
      reset! # the browser is gone: no further request will ever be made

      events('impersonation.start').first
    end

    it 'is closed by the hourly sweep once its hour is up, with an audited expiry' do
      started = abandon!

      # Inside the hour, it is still a live session and nothing touches it.
      expect { HousekeepingJob.new.perform }.not_to(change { events('impersonation.end').count })

      started.update!(created_at: (SupportImpersonation::MAX_DURATION + 5.minutes).ago)

      expect { HousekeepingJob.new.perform }.to(change { events('impersonation.end').count }.by(1))

      ended = events('impersonation.end').first

      expect(ended.details).to include('start_event_id' => started.id, 'ended_by' => 'expired',
                                       'mode' => SupportImpersonation::EDIT_MODE,
                                       'duration_seconds' => SupportImpersonation::MAX_DURATION.to_i)
      expect(ended.account_id).to eq(account.id)
      expect(ended.subject).to eq(admin)
      expect(ended.reason).to eq(reason)
      # Nobody pressed anything: the clock ran out, like `comp.expire`.
      expect(ended.operator).to be_nil

      # And it is written once, however many times the sweep runs.
      expect { HousekeepingJob.new.perform }.not_to(change { events('impersonation.end').count })
    end

    it 'stops the customer’s support-access card saying the session is still running' do
      started = abandon!
      started.update!(created_at: (SupportImpersonation::MAX_DURATION + 5.minutes).ago)

      sign_in(admin)
      get settings_account_path

      expect(response.body).to include(I18n.t('support_access_still_open'))

      HousekeepingJob.new.perform

      get settings_account_path

      expect(response.body).not_to include(I18n.t('support_access_still_open'))
    end

    # A session that ended properly is not touched, and neither is one whose
    # operator came back with the cookie still in hand and ended it themselves.
    it 'leaves a session that wrote its own ending alone' do
      sign_in(operator)
      start!
      delete operator_current_impersonation_path

      expect(events('impersonation.end').count).to eq(1)

      OperatorEvent.where(action: 'impersonation.start').update_all(
        created_at: (SupportImpersonation::MAX_DURATION + 5.minutes).ago
      )

      expect { HousekeepingJob.new.perform }.not_to(change { events('impersonation.end').count })
    end

    # M9. The sweep and the operator's own next request are two writers for one
    # ending. The guard used to write unconditionally, so an operator who came
    # back after the sweep had closed the session added a SECOND end row — and
    # the customer's card pairs start with end, so it printed one and orphaned
    # the other. Both go through SupportImpersonation.record_end! now, which
    # decides under the start row's lock.
    it 'writes one ending when the sweep closes it and the operator then comes back' do
      sign_in(operator)
      start!

      travel(SupportImpersonation::MAX_DURATION + 5.minutes) do
        expect(SupportImpersonation.expire_abandoned!).to eq(1)

        # The operator's browser still holds the session cookie, and their next
        # request finds the hour up and ends the session. The session is
        # theirs to leave — but the LOG already says how it ended, and one
        # start has one ending.
        get templates_path

        expect(events('impersonation.end').count).to eq(1)
        expect(events('impersonation.end').first.details['ended_by']).to eq('expired')
      end
    end

    it 'writes one ending when two sweeps run over the same start' do
      abandon!

      OperatorEvent.where(action: 'impersonation.start').update_all(
        created_at: (SupportImpersonation::MAX_DURATION + 5.minutes).ago
      )

      expect(SupportImpersonation.expire_abandoned!).to eq(1)
      expect(SupportImpersonation.expire_abandoned!).to eq(0)
      expect(events('impersonation.end').count).to eq(1)
    end

    # There is no age floor any more: a seven-day window meant a scheduler
    # outage longer than a week left those sessions saying "In progress" for
    # ever, which is the state the sweep exists to end.
    it 'still closes a session abandoned longer ago than a week' do
      started = abandon!
      started.update!(created_at: 30.days.ago)

      expect { HousekeepingJob.new.perform }.to(change { events('impersonation.end').count }.by(1))
    end

    # N1. The pairing is done in SQL, BEFORE the batch is taken. Doing it after
    # reads the same and is not: `operator_events` is never purged, so once
    # SWEEP_BATCH sessions had been opened and properly closed, every tick
    # fetched the same batch of finished ones, rejected all of them and
    # returned nothing. The sweep was permanently inert, and every session
    # abandoned after that point said "In progress" for ever — the exact state
    # it exists to end.
    it 'closes an abandoned session hiding behind a full batch of finished ones' do
      long_ago = (SupportImpersonation::MAX_DURATION + 5.minutes).ago
      finished = SupportImpersonation::SWEEP_BATCH + 1

      OperatorEvent.insert_all(
        Array.new(finished) do
          { action: 'impersonation.start', account_id: account.id, reason:,
            details: { 'mode' => SupportImpersonation::READ_ONLY_MODE }, created_at: long_ago }
        end
      )

      OperatorEvent.insert_all(
        OperatorEvent.where(action: 'impersonation.start').ids.map do |id|
          { action: 'impersonation.end', account_id: account.id, reason:,
            details: { 'start_event_id' => id, 'ended_by' => 'operator' }, created_at: long_ago }
        end
      )

      started = abandon!
      started.update!(created_at: long_ago)

      expect { HousekeepingJob.new.perform }.to(change { events('impersonation.end').count }.by(1))
      expect(SupportImpersonation.end_row_exists?(started.id)).to be(true)
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
