# frozen_string_literal: true

require 'rake'

# Platform-operator surfaces: the Sidekiq console and the instance-global
# fulltext toggle open only for a user flagged by `rake operator:seed` who has
# enrolled 2FA. Everyone else gets a 404 — the route does not exist for them —
# and no HTTP path can create or promote an operator.
RSpec.describe 'Operator access', type: :request do
  def enroll_two_factor(user)
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)

    user
  end

  # Mirrors how test mode clones an account: the child carries the parent's
  # account_kind, which is exactly why the kind can never be the gate.
  def create_testing_child(parent)
    child = parent.dup.tap { |account| account.name = "Testing - #{parent.name}" }
    child.uuid = SecureRandom.uuid
    parent.testing_accounts << child
    parent.save!

    child
  end

  # An account admin can flip otp_required_for_login on another user without
  # any OTP ever being entered; only real enrollment leaves a secret behind, so
  # the flag alone is not 2FA.
  def create_operator_flagged_without_secret
    create(:user, :admin, account: operator_account, platform_operator: true).tap do |user|
      user.update!(otp_required_for_login: true, otp_secret: nil)
    end
  end

  let(:operator_account) { create(:account, :operator) }
  let(:operator) { enroll_two_factor(create(:user, :admin, account: operator_account, platform_operator: true)) }
  let(:customer_admin) { create(:user, :admin, account: create(:account)) }
  let(:internal_admin) { create(:user, :admin, account: create(:account, :internal)) }

  after { Docuseal.refresh_fulltext_search! }

  describe 'GET /jobs' do
    it 'serves the console to a platform operator with 2FA' do
      sign_in(operator)

      get '/jobs'

      expect(response).to have_http_status(:ok)
    end

    # Everyone who is not an operator with enrolled 2FA meets the same closed
    # door. One row per identity; each row is its own example and carries its
    # own setup and its own extra assertions.
    [
      ['an anonymous visitor', -> {}],
      ['a customer admin', -> { customer_admin }],
      ['an internal admin', -> { internal_admin }],
      ['an operator-flagged user without 2FA',
       -> { create(:user, :admin, account: operator_account, platform_operator: true) }],
      ['an operator-flagged user whose 2FA flag has no secret',
       -> { create_operator_flagged_without_secret }],
      ['an admin inside a testing child of the operator account',
       lambda {
         testing_child = create_testing_child(operator_account)

         enroll_two_factor(create(:user, :admin, account: testing_child)).tap do |testing_admin|
           expect(testing_child.account_kind).to eq(Account::OPERATOR_KIND)
           expect(testing_admin.platform_operator).to be(false)
         end
       }]
    ].each do |description, build_user|
      it "has no route for #{description}" do
        user = instance_exec(&build_user)

        sign_in(user) if user

        expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe 'POST /settings/search_entries_reindex' do
    # The operator surface answers everyone else with a 404 and writes nothing:
    # no config row on any account, no reindex job queued. HTML gets the
    # routing error, a non-HTML request an empty 404 body — never a redirect to
    # sign-in. One row per identity and format.
    [
      ['is a 404 for a customer admin and writes nothing', :html, -> { customer_admin }],
      ['is a 404 for an internal admin and writes nothing', :html, -> { internal_admin }],
      ['is a 404 for an anonymous visitor, never a redirect to sign-in', :html, -> {}],
      ['is a 404 for an operator-flagged user whose 2FA flag has no secret', :html,
       -> { create_operator_flagged_without_secret }],
      ['is an empty 404 for a non-HTML request', :json, -> { customer_admin }],
      ['is an empty 404 for an anonymous non-HTML request', :json, -> {}]
    ].each do |description, format, build_user|
      it description do
        operator_account
        user = instance_exec(&build_user)

        sign_in(user) if user

        if format == :html
          expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
        else
          post settings_search_entries_reindex_index_path, as: format

          expect(response).to have_http_status(:not_found)
          expect(response.body).to be_empty
        end

        expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
        expect(ReindexAllSearchEntriesJob.jobs).to be_empty
      end
    end

    it 'lets the operator start the reindex and lands the flag on the operator account only' do
      customer_admin
      internal_admin
      sign_in(operator)

      expect(Docuseal.fulltext_search?).to be(false)

      post settings_search_entries_reindex_index_path, headers: { 'HTTP_REFERER' => settings_account_path }

      expect(response).to redirect_to(settings_account_path)
      expect(ReindexAllSearchEntriesJob.jobs.size).to eq(1)

      flag_rows = AccountConfig.where(key: 'fulltext_search')

      expect(flag_rows.sole.account).to eq(operator_account)
      expect(flag_rows.sole.value).to be(true)
      expect(AccountConfig.where(key: 'fulltext_search').where.not(account: operator_account)).not_to exist
      expect(Docuseal.fulltext_search?).to be(true)
    end

    it 'keeps working for the operator in test mode and lands the flag on the real operator account' do
      sign_in(operator)

      post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

      expect(response).to have_http_status(:redirect)

      testing_child = operator_account.testing_accounts.reload.sole

      expect(testing_child.account_kind).to eq(Account::OPERATOR_KIND)
      expect(testing_child.users.sole.platform_operator).to be(false)
      expect(OperatorConfigs.candidates.pluck(:id)).to eq([operator_account.id])

      get '/jobs'

      expect(response).to have_http_status(:ok)

      post settings_search_entries_reindex_index_path, headers: { 'HTTP_REFERER' => settings_account_path }

      expect(response).to redirect_to(settings_account_path)
      expect(ReindexAllSearchEntriesJob.jobs.size).to eq(1)

      flag_rows = AccountConfig.where(key: 'fulltext_search')

      expect(flag_rows.sole.account).to eq(operator_account)
      expect(flag_rows.sole.value).to be(true)
      expect(testing_child.account_configs.where(key: 'fulltext_search')).not_to exist
      expect(Docuseal.fulltext_search?).to be(true)
    end

    it 'stays a 404 for an internal admin in test mode' do
      operator_account
      sign_in(internal_admin)

      post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

      expect(response).to have_http_status(:redirect)
      expect(internal_admin.account.testing_accounts.reload.size).to eq(1)

      expect { get '/jobs' }.to raise_error(ActionController::RoutingError)
      expect { post settings_search_entries_reindex_index_path }.to raise_error(ActionController::RoutingError)
      expect(AccountConfig.exists?(key: 'fulltext_search')).to be(false)
      expect(ReindexAllSearchEntriesJob.jobs).to be_empty
    end

    it 'shows the reindex control only to the operator' do
      operator_account

      sign_in(internal_admin)
      get settings_account_path
      expect(response.body).not_to include(settings_search_entries_reindex_index_path)

      sign_in(operator)
      get settings_account_path
      expect(response.body).to include(settings_search_entries_reindex_index_path)
    end
  end

  describe 'OperatorConfigs' do
    # Test mode clones the operator account into a child that carries the same
    # account_kind, so two accounts match the kind. Every read and write must
    # still resolve to the real (non-testing) operator account.
    it 'resolves the real operator account, never its testing child' do
      sign_in(operator)

      post testing_account_path, headers: { 'HTTP_REFERER' => root_url }

      expect(response).to have_http_status(:redirect)

      testing_child = operator_account.testing_accounts.reload.sole

      expect(testing_child.testing?).to be(true)

      # Set-based, so the pin holds whichever row the database would hand a
      # bare LIMIT 1 first: both rows match the kind, only the parent is a
      # candidate.
      expect(Account.where(account_kind: Account::OPERATOR_KIND).pluck(:id))
        .to contain_exactly(operator_account.id, testing_child.id)
      expect(OperatorConfigs.candidates.pluck(:id)).to eq([operator_account.id])

      expect(OperatorConfigs.account).to eq(operator_account)
      expect(OperatorConfigs.enabled?(:fulltext_search)).to be(false)

      OperatorConfigs.set!(:fulltext_search, true)

      expect(OperatorConfigs.enabled?(:fulltext_search)).to be(true)
      expect(operator_account.account_configs.find_by!(key: 'fulltext_search').value).to be(true)
      expect(testing_child.account_configs.where(key: 'fulltext_search')).not_to exist
      expect(AccountConfig.where(key: 'fulltext_search').sole.account).to eq(operator_account)
    end
  end

  describe 'no HTTP path creates or promotes an operator' do
    # The operator flag is written by exactly one path: `rake operator:seed`
    # (lib/tasks/operator.rake). Nothing else under app/ or lib/ — models,
    # jobs, mailers and views included — may name it, except a short list of
    # READS, each pinned by its exact line: the two in app/models/user.rb (the
    # schema annotation and the `operator_access?` predicate), and the two in
    # the operator console's user table, which draws a badge beside anybody
    # holding the flag (Session 8). That badge is worth its pin: it is how an
    # operator sees at a glance that a login carries platform access — a
    # mis-provisioned one included, which `operator_access?` would hide
    # because it also demands 2FA. Both pinned lines are pure reads inside a
    # view that only an enrolled operator can reach, and neither can assign
    # anything. And nothing may `permit!` a whole request payload — that is
    # how a mass-assigned `platform_operator: true` would slip in.
    it 'never mentions platform_operator outside the operator seed and the two user.rb reads, ' \
       'and never permit!s a payload' do
      allowed_reads = {
        'app/models/user.rb' => [
          /\A#\s+platform_operator\s+:boolean\s+default\(FALSE\), not null\z/,
          /\Aplatform_operator\? && otp_required_for_login\? && otp_secret\.present\?\z/
        ],
        'app/views/operator/accounts/_users.html.erb' => [
          /\A<% if user\.platform_operator\? %>\z/,
          %r{\A<span class="[^"]*" data-platform-operator><%= t\('operator_users_platform_operator'\) %></span>\z}
        ],
        # Session 8 phase C, and the same kind of read: support impersonation
        # REFUSES anybody carrying platform access. One line decides whether
        # the console offers the door (SupportImpersonation.viewable?, which
        # the user table above asks), and one line refuses it again in the
        # controller that opens it. Both are pure reads inside a negation;
        # neither can assign anything.
        'lib/support_impersonation.rb' => [
          /\Auser\.role != 'integration' && !user\.platform_operator\?\z/
        ],
        'app/controllers/operator/impersonations_controller.rb' => [
          /\Araise Refused, t\('operator_impersonation_refused_operator_user'\) if user\.platform_operator\?\z/
        ]
      }

      operator_hits = Rails.root.glob('{app,lib}/**/*.{rb,rake,erb,yml,yaml,js,vue,ts}').flat_map do |path|
        relative = path.relative_path_from(Rails.root).to_s
        next [] if relative == 'lib/tasks/operator.rake'

        File.foreach(path).with_index(1).filter_map do |line, number|
          next unless line.include?('platform_operator')
          next if allowed_reads.fetch(relative, []).any? { |pattern| line.strip.match?(pattern) }

          "#{relative}:#{number}: #{line.strip}"
        end
      end
      permit_hits = Rails.root.glob('{app,lib}/**/*.{rb,rake,erb}').select do |path|
        File.read(path).match?(/\bpermit!/)
      end

      expect(operator_hits).to be_empty
      expect(permit_hits).to be_empty
    end

    it 'ignores platform_operator and unknown roles on an admin user update' do
      account = create(:account, :internal)
      admin = create(:user, :admin, account:)
      target = create(:user, :editor, account:)
      sign_in(admin)

      patch user_path(target), params: {
        user: { first_name: 'Promoted', platform_operator: true, role: 'superadmin' }
      }

      expect(response).to have_http_status(:redirect)
      expect(target.reload.first_name).to eq('Promoted')
      expect(target.platform_operator).to be(false)
      expect(target.role).to eq(User::EDITOR_ROLE)
    end

    it 'accepts only the existing roles on an invitation' do
      account = create(:account, :internal)
      sign_in(create(:user, :admin, account:))

      post users_path, params: {
        user: { email: 'golden-role-injection@example.com', first_name: 'Role', last_name: 'Probe',
                role: 'superadmin', platform_operator: true }
      }

      invited = User.find_by!(email: 'golden-role-injection@example.com')

      expect(invited.role).to eq(User::ADMIN_ROLE)
      expect(invited.platform_operator).to be(false)

      post users_path, params: {
        user: { email: 'golden-role-viewer@example.com', first_name: 'Role', last_name: 'Probe', role: 'viewer' }
      }

      expect(User.find_by!(email: 'golden-role-viewer@example.com').role).to eq(User::VIEWER_ROLE)
    end

    describe 'provisioning' do
      stash_env('ADMIN_PROVISION_TOKEN')

      before { ENV['ADMIN_PROVISION_TOKEN'] = 'golden-operator-provision-token' }

      it 'ignores platform_operator, role and account_kind' do
        post '/api/admin/accounts',
             headers: { 'x-admin-token': 'golden-operator-provision-token', 'content-type': 'application/json' },
             params: {
               name: 'Provisioned Firm', email: 'golden-provisioned-operator@example.com',
               platform_operator: true, role: 'superadmin', account_kind: Account::OPERATOR_KIND,
               user: { platform_operator: true }
             }.to_json

        expect(response).to have_http_status(:created)

        user = User.find_by!(email: 'golden-provisioned-operator@example.com')

        expect(user.platform_operator).to be(false)
        expect(user.role).to eq(User::ADMIN_ROLE)
        expect(user.account.account_kind).to eq(Account::INTERNAL_KIND)
      end
    end

    describe 'operator:seed' do
      stash_env('OPERATOR_EMAIL', 'OPERATOR_PASSWORD')

      before { Rails.application.load_tasks unless Rake::Task.task_defined?('operator:seed') }

      after { Rake::Task['operator:seed'].reenable }

      it 'refuses to run without OPERATOR_PASSWORD and never generates one' do
        ENV['OPERATOR_EMAIL'] = 'golden-operator@example.com'
        ENV.delete('OPERATOR_PASSWORD')

        expect do
          expect { Rake::Task['operator:seed'].invoke }.to raise_error(SystemExit)
        end.to output(/OPERATOR_PASSWORD is required/).to_stderr

        expect(Account.exists?(account_kind: Account::OPERATOR_KIND)).to be(false)
        expect(User.exists?(email: 'golden-operator@example.com')).to be(false)
      end
    end
  end
end
